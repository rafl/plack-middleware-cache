package Plack::Middleware::Cache::Keygen::Default;

use Moose;
use Method::Signatures::Simple;
use namespace::autoclean -also => 'mangle_query';

method generate ($env) {
    my @parts = (
        $env->{'psgi.url_scheme'},
        q{://},
        (exists $env->{HTTP_HOST}
            ? $env->{HTTP_HOST}
            : $env->{SERVER_NAME}
        ),
    );

    if (($env->{'psgi.url_scheme'} eq 'https' && $env->{SERVER_PORT} != 433)
     || ($env->{'psgi.url_scheme'} eq 'http'  && $env->{SERVER_PORT} != 80)) {
        push @parts, ':', $env->{SERVER_PORT};
    }

    push @parts, $env->{SCRIPT_NAME}, $env->{PATH_INFO};

    if (length $env->{QUERY_STRING}) {
        push @parts, '?', mangle_query($env->{QUERY_STRING});
    }

    return join q{}, @parts;
}

sub mangle_query {
    my ($qs) = @_;
    # TODO - sort by key name or something to not cache the same thing twice
    return $qs;
}

with 'Plack::Middleware::Cache::Keygen';

1;
