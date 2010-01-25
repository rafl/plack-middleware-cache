package Plack::Middleware::Cache::CacheControl;

use Moose;
use Method::Signatures::Simple;
use namespace::autoclean;

has input => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    required => 1,
);

has _parsed_input => (
    traits  => [qw(Hash)],
    is      => 'ro',
    isa     => 'HashRef',
    builder => '_build__parsed_input',
    handles => {
        _exists => 'exists',
        _get    => 'get',
        _set    => 'set',
        _unset  => 'delete',
        keys    => 'keys',
    },
);

override BUILDARGS => method (@args) {
    return {
        input => $args[0],
    } if @args == 1 && !ref $args[0];

    super;
};

method _build__parsed_input {
    my $in = $self->input;

    return {} if !defined $in || !length $in;

    $in =~ s/\s+//g;

    return {
        map {
            my ($k, $v) = split '=', $_, 2;
            ($k => $v);
        } split q{,}, $in
    };
}

method get ($k) {
    return unless $self->_exists($k);
    my $v = $self->_get($k);
    return defined $v ? $v : 1
}

method set_private {
    $self->_set(private => undef);
    $self->_unset('public');
}

method set_ttl ($seconds) {
    $self->_set('s-maxage' => $seconds);
}

method stringify {
    my @ret;

    my $d = $self->_parsed_input;
    while (my ($k, $v) = each %{ $d }) {
        push @ret, !defined $v ? $k : join q{=} => $k, $v;
    }

    return join q{,} => @ret;
}

__PACKAGE__->meta->make_immutable;

1;
