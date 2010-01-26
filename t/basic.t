use strict;
use warnings;
use Test::More;
use Plack::Test;
use HTTP::Date;
use HTTP::Request;
use HTTP::Request::Common;
use Storable qw(freeze thaw);
use MIME::Base64;

use Plack::Middleware::Cache;
use Plack::Middleware::Cache::Store;

my $backend_app = sub {
    my ($env) = @_;

    if (my $res = $env->{HTTP_X_PLACK_CACHE_TEST_RESPONSE}) {
        return thaw(decode_base64($res));
    }

    if ($env->{PATH_INFO} eq '/simple') {
        return [ 200, ['Content-Type' => 'text/plain'], ['moo'] ];
    }

    if ($env->{PATH_INFO} eq '/delayed') {
        return sub {
            shift->([ 200, ['Content-Type' => 'text/plain'], ['moo'] ])
        };
    }

    if ($env->{PATH_INFO} eq '/streaming') {
        return sub {
            my $writer = shift->([ 200, ['Content-Type' => 'text/plain'] ]);
            $writer->write($_) for qw/moo kooh/;
            $writer->close;
        };
    }

    return [ 404, ['Content-Type' => 'text/plain'], [] ];
};

my $app = Plack::Middleware::Cache->wrap($backend_app);

test_psgi $app => sub {
    my ($cb) = @_;

    subtest 'simple response' => sub {
        my $res = $cb->(GET '/simple');
        ok($res->is_success, 'status');
        is($res->content, 'moo', 'content');
        done_testing;
    };

    subtest 'delayed response' => sub {
        my $res = $cb->(GET '/delayed');
        ok($res->is_success, 'status');
        is($res->content, 'moo', 'content');
        done_testing;
    };

    subtest 'streaming response' => sub {
        my $res = $cb->(GET '/streaming');
        ok($res->is_success, 'status');
        is($res->content, 'mookooh', 'content');
        done_testing;
    };

    subtest 'passes on non-GET/HEAD' => sub {
        my ($res, $trace) = inject_response(
            $cb, POST('/'),
            [ 200, ['Content-Type' => 'text/plain'], [] ],
        );
        ok($res->is_success, 'status');
        is_deeply($trace, [qw(invalidate pass)], 'trace');
        ok(!defined $res->header('Age'), 'no Age');
        done_testing;
    };

    for my $method (qw(POST PUT DELETE)) {
        subtest "invalidates on ${method} request" => sub {
            my ($res, $trace) = inject_response(
                $cb, HTTP::Request->new($method => '/'),
                [200, ['Content-Type' => 'text/plain'], [] ],
            );
            ok($res->is_success, 'status');
            is_deeply($trace, [qw(invalidate pass)], 'trace');
            done_testing;
        };
    }

    for my $private_header (qw(Authorization Cookie)) {
        subtest "does not cache with ${private_header} request header and non public response" => sub {
            my ($res, $trace) = inject_response(
                $cb, GET('/', $private_header => 'basic=mookooh'),
                [ 200, ['Content-Type' => 'text/plain', 'ETag' => '"moo"'], [] ],
            );
            ok($res->is_success, 'status');
            is($res->header('Cache-Control'), 'private', 'cache-control');
            is_deeply($trace, [qw(miss)], 'trace');
            ok(!defined $res->header('Age'), 'no Age');
            done_testing;
        };

        subtest "does cache with ${private_header} request header and public response" => sub {
            my ($res, $trace) = inject_response(
                $cb, GET('/', $private_header => 'basic mookooh',),
                [ 200, ['Content-Type' => 'text/plain', 'ETag' => '"moo"', 'Cache-Control' => 'public'], [] ],
            );
            ok($res->is_success, 'status');
            is_deeply($trace, [qw(miss store)], 'trace');
            ok(defined $res->header('Age'), 'has Age');
            is($res->header('Cache-Control'), 'public', 'public response');
            done_testing;
        };
    }

    subtest 'responds with 304 when If-Modified-Since matches Last-Modified' => sub {
        my $time = time2str(time);
        my ($res, $trace) = inject_response(
            $cb, GET('/', 'If-Modified-Since' => $time),
            [ 200, ['Content-Type' => 'text/plain', 'Last-Modified' => $time], ['moo'] ],
        );
        is($res->code, 304, 'status');
        ok(!defined $res->header('Content-Type'), 'no Content-Type');
        ok(!defined $res->header('Content-Length'), 'no Content-Length');
        ok(!length $res->content, 'no content');
        is_deeply($trace, [qw(miss store)], 'trace');
        done_testing;
    };

    subtest 'responds with 304 when If-None-Match matches ETag' => sub {
        my ($res, $trace) = inject_response(
            $cb, GET('/', 'If-None-Match' => '12345'),
            [ 200, ['Content-Type' => 'text/plain', 'ETag' => '12345'], ['moo'] ],
        );
        is($res->code, 304, 'status');
        ok(!defined $res->header('Content-Type'), 'no Content-Type');
        ok(!defined $res->header('Content-Length'), 'no Content-Length');
        is($res->header('ETag'), '12345', 'got ETag');
        ok(!length $res->content, 'no content');
        is_deeply($trace, [qw(miss store)], 'trace');
        done_testing;
    };

    subtest 'responds with 304 only if If-None-Match and If-Modified-Since both match' => sub {
        my $time = time;
        my $response = [
            200,
            ['Content-Type' => 'text/plain', 'ETag' => '12345', 'Last-Modified' => str2time($time)],
            ['moo'],
        ];

        subtest 'only etag' => sub {
            my ($res, $trace) = inject_response(
                $cb, GET('/', 'ETag' => '12345', 'If-Modified-Since' => str2time($time - 1)),
                $response,
            );
            is($res->code, 200, 'status');
            done_testing;
        };

        subtest 'only last-modified' => sub {
            my ($res, $trace) = inject_response(
                $cb, GET('/', 'ETag' => '54321', 'If-Modified-Since' => str2time($time)),
                $response,
            );
            is($res->code, 200, 'status');
            done_testing;
        };

        subtest 'both' => sub {
            my ($res, $trace) = inject_response(
                $cb, GET('/', 'ETag' => '12345', 'If-Modified-Since' => str2time($time)),
                $response,
            );
            is($res->code, 304, 'status');
        };

        done_testing;
    };
};

sub inject_response {
    my ($cb, $req, $response) = @_;
    $req->header('X-Plack-Cache-Test-Response' => encode_base64(freeze($response)));
    my $res = $cb->($req);
    return ($res, [split q{,} => $res->header('X-Plack-Cache-Trace')]);
}

done_testing;
