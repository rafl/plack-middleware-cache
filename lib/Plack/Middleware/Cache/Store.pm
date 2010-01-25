package Plack::Middleware::Cache::Store;

use Moose;
use CHI;
use Method::Signatures::Simple;
use Plack::Middleware::Cache::Keygen::Default;
use namespace::autoclean;

has cache => (
    is      => 'ro',
    builder => '_build_cache',
    handles => {
        _is_valid => 'is_valid',
        _get      => 'get',
        _lookup   => 'get_object',
        _store    => 'set',
    },
);

has keygen => (
    does    => 'Plack::Middleware::Cache::Keygen',
    builder => '_build_keygen',
    handles => {
        _cache_key => 'generate',
    },
);

method _build_cache {
    return CHI->new(
        driver       => 'Memory',
        datastore    => {},
        on_set_error => 'die',
        on_get_error => 'die',
    );
}

method _build_keygen {
    return Plack::Middleware::Cache::Keygen::Default->new;
}

method is_stored ($env) {
    my $key = $self->_cache_key($env);
    return $self->_is_valid($key);
}

method get ($env) {
    return $self->_get($self->_cache_key($env));
}

method lookup ($env) {
    my $key = $self->_cache_key($env);
    my $cache_obj = $self->_lookup($key);
}

method _env_for_store ($env) {
    # TODO: we most likely don't want to store most of it
    return {
        map {
            /^psgi\./
                ? ()
                : ($_ => $env->{$_})
        } keys %{ $env }
    };
}

method _res_for_store ($res) {
    # TODO: we most likely don't want to store most of it
    my @headers;
    Plack::Util::header_iter($res->[1], sub {
        push @headers, @_ if $_[0] ne 'Age'
    });
    return [ $res->[0], \@headers, $res->[2] ];
}

method _requests_match ($vary, $env1, $env2) {
    return 1 if !defined $vary || !length $vary;
    return 0 if $vary eq '*';
    return all {
        $env1->{$_} eq $env2->{$_}
    } map {
        s/-/_/g; $_
    } map {
        uc
    } split /\s*,\s*/ => $vary;
}

method store ($env, $res) {
    my $key = $self->_cache_key($env);
    my $store_env = $self->_env_for_store($env);
    my $store_res = $self->_res_for_store($res);

    # for now we'll store all about requests and responses, including the bodys
    # for everything with a unique url in one bucket. that's probably a bad
    # thing that should be fixed later, for example by having a separate store
    # for bodies.

    my $vary = Plack::Util::header_get($res->[1], 'Vary');

    my $entries = $self->_get($key) || [];
    $entries = [map {
        my ($env_i, $res_i) = @_;
        defined $vary
          && Plack::Util::header_exists($res_i, 'Vary')
          && $vary eq Plack::Util::header_get($res_i, 'Vary')
          && $self->_requests_match($vary, $env_i, $store_env)
    } @{ $entries }];

    unshift @{ $entries }, [$store_env, $store_res];

    $self->_store($key => $entries);
}

__PACKAGE__->meta->make_immutable;

1;
