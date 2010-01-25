package Plack::Middleware::Cache;

use Carp;
use Moose;
use Try::Tiny;
use HTTP::Date;
use Plack::Util;
use MooseX::NonMoose;
use List::Util qw(max);
use List::MoreUtils qw(any);
use Method::Signatures::Simple;
use Plack::Middleware::Cache::CacheControl;
use namespace::autoclean;

extends 'Plack::Middleware';

has allow_reload => (
    is      => 'ro',
    isa     => 'Bool',
    default => 1,
);

has allow_revalidate => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);

{
    use Moose::Util::TypeConstraints;
    my $tc = subtype as 'Int', where { $_ > 0 };

    has default_ttl => (
        is        => 'ro',
        isa       => $tc,
        predicate => '_has_default_ttl',
    );
}

has private_headers => (
    is      => 'ro',
    isa     => 'ArrayRef[Str]',
    default => sub { [qw(Authorization Cookie)] },
);

has _private_headers => (
    is      => 'ro',
    isa     => 'ArrayRef[Str]',
    lazy    => 1,
    builder => '_build_private_headers',
);

with 'MooseX::Role::BuildInstanceOf' => {
    target => 'Plack::Middleware::Cache::Store',
    prefix => 'store',
};

method _build_private_headers {
    return [map {
        (my $h = $_) =~ s/-/_/g;
        'HTTP_' . uc $h
    } @{ $self->private_headers }];
}

method BUILD {
    $self->_private_headers;
}

method call ($env) {
    $env->{'plack.cache.trace'} = [];

    my $res = $self->handle($env);

    if (ref $res eq 'ARRAY') {
        Plack::Util::header_set($res->[1], 'X-Plack-Cache-Trace', join q{,} => @{ $env->{'plack.cache.trace'} });
    }

    # tidy response, clear body on HEAD, ...

    return $res;
}

method handle ($env) {
    if ($env->{REQUEST_METHOD} ne 'GET' && $env->{REQUEST_METHOD} ne 'HEAD') {
        return $self->invalidate($env);
    }

    if (exists $env->{HTTP_EXPECT}) {
        return $self->pass($env);
    }

    return $self->lookup($env);
}

method record ($env, $event) {
    push @{ $env->{'plack.cache.trace'} }, $event;
}

method forward ($env) {
    return $self->app->($env);
}

method pass ($env) {
    $self->record($env, 'pass');
    return $self->forward($env);
}

method _response_max_age ($res, $cc) {
    my $max_age = $cc->get('s-maxage') || $cc->get('max-age');
    return $max_age if defined $max_age;

    return unless Plack::Util::header_exists($res->[1], 'Expires');
    my $expires = str2time(Plack::Util::header_get($res->[1], 'Expires'));
    return unless defined $expires;

    return unless Plack::Util::header_exists($res->[1], 'Date');
    my $date = str2time(Plack::Util::header_get($res->[1], 'Date'));
    return unless defined $date;

    return $expires - $date;
}

method _response_ttl ($res, $cc) {
    my $max_age = $self->_response_max_age($res, $cc);
    return unless $max_age;
    return $max_age - $self->_response_age($res, $cc);
}

method _response_age ($res, $cc) {
    if (Plack::Util::header_exists($res->[1], 'Age')) {
        return 0 + Plack::Util::header_get($res->[1], 'Age');
    }

    my $date = Plack::Util::header_exists($res->[1], 'Date')
        ? str2time(Plack::Util::header_get($res->[1], 'Date'))
        : time;
    $date = time unless defined $date;
    return max($date, 0);
}

{
    my %response_code_is_cacheable = map {
        ($_ => 1)
    } qw(200 203 300 301 302 404 410);

    method _response_cacheable ($res, $cc) {
        return unless $response_code_is_cacheable{ $res->[0] };
        return if $cc->get('no-store') || $cc->get('private');

        # validateable
        return 1 if Plack::Util::header_exists($res->[1], 'Last-Modified')
                 || Plack::Util::header_exists($res->[1], 'ETag');

        # fresh
        my $ttl = $self->_response_ttl($res, $cc);
        return $ttl && $ttl > 0;
    }
}

method cache ($env, $res) {
    $self->record($env, 'store');
    #$self->store->store($env, $res);
}

method finalize ($env, $res) {
    Plack::Util::header_set($res->[1], 'X-Plack-Cache-Trace', join q{,} => @{ $env->{'plack.cache.trace'} });
    return $res;
}

method handle_response ($env, $res) {
    my $cc = Plack::Middleware::Cache::CacheControl->new(
        scalar Plack::Util::header_get($res->[1], 'Cache-Control'),
    );

    if ((any { exists $env->{$_} } @{ $self->_private_headers })
     && !$cc->get('public')) {
        $cc->set_private;
        Plack::Util::header_set($res->[1], 'Cache-Control', $cc->stringify);
        return $self->finalize($env, $res);
    }
    elsif ($self->_has_default_ttl &&
           !defined $self->_response_ttl($res, $cc) &&
           !$cc->get('must_revalidate')) {
        $cc->set_ttl($self->default_ttl);
        Plack::Util::header_set($res->[1], 'Cache-Control', $cc->stringify);
    }

    $self->cache($env, $res)
        if $self->_response_cacheable($res, $cc);

    Plack::Util::header_set($res->[1], 'Age', $self->_response_age($res, $cc));

    return $self->finalize($env, $res);
}

method handle_delayed_response ($env, $res, $respond) {
    my ($status, $headers, $body) = @{ $res };

    if ($body) {
        $self->handle_response($env, $res);
        return $respond->($res);
    }

    my $writer = $respond->($res);

    my @buf;
    return Plack::Util::inline_object
        write => sub {
            push @buf, $_[0];
            $writer->write($_[0]);
        },
        close => sub {
            $self->handle_response($env, [ $status, $headers, \@buf ]);
            $writer->close
        };
}

method fetch ($env) {
    $env->{REQUEST_METHOD} = 'GET';
    delete @{ $env }{qw(HTTP_IF_MODIFIED_SINCE HTTP_IF_NONE_MATCH)};

    my $res = $self->forward($env);

    if (ref $res eq 'ARRAY') {
        return $self->handle_response($env, $res);
    }

    if (ref $res eq 'CODE') {
        return sub {
            my ($respond) = @_;
            return $res->(sub {
                return $self->handle_delayed_response($env, $_[0], $respond);
            });
        };
    }

    croak 'Invalid response';
}

method fresh_enough ($entry, $env, $cc) {
    return 0 unless $entry->fresh;
    return 1 if !$self->allow_revalidate || !$cc->exists('max-age');

    my $max_age = $cc->get('max-age');
    return $max_age > 0 && $max_age >= $entry->age;
}

method validate ($entry, $env) {
    $env->{REQUEST_METHOD} = 'GET';
    $env->{HTTP_IF_MODIFIED_SINCE} = $entry->last_modified;

    # set etags in env

    my $res = $self->forward($env);

    # status 304 not modified ...

    # update and store if cachable

    # send out
}

method lookup ($env) {
    my $cc = Plack::Middleware::Cache::CacheControl->new($env->{HTTP_CACHE_CONTROL});

    if ($cc->get('no-cache') || (exists $env->{HTTP_PRAGMA} && $env->{HTTP_PRAGMA} eq 'no-cache')) {
        if ($self->allow_reload) {
            $self->record($env, 'reload');
            return $self->fetch($env);
        }
    }

    unless ($self->store->is_stored($env)) {
        $self->record($env, 'miss');
        return $self->fetch($env)
    }

    my $entry = $self->store->get($env);

    if ($self->fresh_enough($entry, $env, $cc)) {
        $self->record($env, 'fresh');
        #$entry->set_age
        #return $entry
        return;
    }

    $self->record($env, 'stale');
    return $self->validate($entry);
}

method invalidate ($env) {
    # $self->store->invalidate
    $self->record($env, 'invalidate');
    return $self->pass($env);
}

__PACKAGE__->meta->make_immutable;

1;
