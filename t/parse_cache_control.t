use strict;
use warnings;
use Test::More;

use Plack::Middleware::Cache::CacheControl;

my @tests = (
    ['undef gives empty hashref',
        undef,
        [],
    ],
    ['empty string gives empty hashref',
        '',
        [],
    ],
    ['single value',
        'max-age=600',
        { 'max-age' => 600 },
    ],
    ['single boolean',
        'no-cache',
        { 'no-cache' => 1 },
    ],
    ['multiple values',
        'max-age=600, max-stale=300, min-fresh=570',
        { 'max-age' => 600, 'max-stale' => 300, 'min-fresh' => 570 },
    ],
    ['multiple values with boolean',
        'max-age=600, foo',
        { 'max-age' => 600, 'foo' => 1 },
    ],
    ['all kinds of stuff',
        'max-age=600,must-revalidate,min-fresh=3000,foo=bar,baz',
        { 'max-age' => 600, 'must-revalidate' => 1, 'min-fresh' => 3000, 'foo' => 'bar', 'baz' => 1 },
    ],
    ['space stripping',
        '   public,   max-age =   600  ',
        { 'public' => 1, 'max-age' => 600 },
    ],
);

for my $test (@tests) {
    my ($desc, $in, $out) = @{ $test };
    subtest $desc => sub {
        my $cc = Plack::Middleware::Cache::CacheControl->new($in);

        if (ref $out eq 'HASH') {
            while (my ($k, $v) = each %{ $out }) {
                is($cc->get($k), $v);
            }
        }
        elsif (ref $out eq 'ARRAY') {
            is_deeply([$cc->keys], $out);
        }

        done_testing;
    };
}

done_testing;
