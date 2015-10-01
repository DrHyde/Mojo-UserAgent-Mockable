use 5.014;

use File::Slurp qw/slurp/;
use File::Temp;
use FindBin qw($Bin);
use Mojo::JSON qw(encode_json decode_json);
use Mojo::UserAgent::Mockable;
use Mojolicious::Quick;
use Test::Most;
use TryCatch;

my $TEST_FILE_DIR = qq{$Bin/files};
my $COUNT         = 5;
my $MIN           = 0;
my $MAX           = 1e9;
my $COLS          = 1;
my $BASE          = 10;

my %args = @_;

my $dir = File::Temp->newdir;

my $url = Mojo::URL->new(q{https://www.random.org/integers/})->query(
    num    => $COUNT,
    min    => $MIN,
    max    => $MAX,
    col    => $COLS,
    base   => $BASE,
    format => 'plain',
);
my $app = $args{'app'};

my $output_file = qq{$dir/output.json};

# Record the interchange
my ( @results, @transactions );
{    # Look! Scoping braces!
    my $mock = Mojo::UserAgent::Mockable->new( mode => 'record', file => $output_file );
    $mock->transactor->name('kit.peters@broadbean.com');

    push @transactions, $mock->get( $url->clone->query( [ quux => 'alpha' ] ) );
    push @transactions, $mock->get( $url->clone->query( [ quux => 'beta' ] ) );

    @results = map { [ split /\n/, $_->res->text ] } @transactions;

    plan skip_all => 'Remote not responding properly'
        unless ref $results[0] eq 'ARRAY' && scalar @{ $results[0] } == $COUNT;
    $mock->save;
}

BAIL_OUT('Output file does not exist') unless ok(-e $output_file, 'Output file exists');

my $mock = Mojo::UserAgent::Mockable->new( mode => 'playback', file => $output_file );
$mock->transactor->name('kit.peters@broadbean.com');

my @mock_results;
my @mock_transactions;

for ( 0 .. $#transactions ) {
    my $transaction = $transactions[$_];
    my $result      = $results[$_];

    my $mock_transaction = $mock->get( $transaction->req->url->clone );
    my $mock_result      = [ split /\n/, $mock_transaction->res->text ];
    my $mock_headers     = $mock_transaction->res->headers->to_hash;
    is $mock_headers->{'X-MUA-Mockable-Regenerated'}, 1, 'X-MUA-Mockable-Regenerated header present and correct';
    delete $mock_headers->{'X-MUA-Mockable-Regenerated'};

    is_deeply( $mock_result, $result, q{Result correct} );
    is_deeply( $mock_headers, $transaction->res->headers->to_hash, q{Response headers correct} );
}

subtest 'null on unrecognized' => sub {
    my $mock = Mojo::UserAgent::Mockable->new( mode => 'playback', file => $output_file, unrecognized => 'null' );

    for ( 0 .. $#transactions ) {
        my $index       = $#transactions - $_;
        my $transaction = $transactions[$index];

        my $mock_transaction;
        lives_ok { $mock_transaction = $mock->get( $transaction->req->url->clone ) } qq{GET did not die (TXN $index)};
        is $mock_transaction->res->text, '', qq{Request out of order returned null (TXN $index)};
    }
};

subtest 'exception on unrecognized' => sub {
    my $mock = Mojo::UserAgent::Mockable->new( mode => 'playback', file => $output_file, unrecognized => 'exception' );

    for ( 0 .. $#transactions ) {
        my $index       = $#transactions - $_;
        my $transaction = $transactions[$index];

        throws_ok { $mock->get( $transaction->req->url->clone ) } qr/^Unrecognized request: URL query mismatch/;
    }
};

subtest 'fallback on unrecognized' => sub {
    my $mock = Mojo::UserAgent::Mockable->new( mode => 'playback', file => $output_file, unrecognized => 'fallback' );

    for ( 0 .. $#transactions ) {
        my $index       = $#transactions - $_;
        my $transaction = $transactions[$index];
        my $result      = $results[$index];

        my $tx;
        lives_ok { $tx = $mock->get( $transaction->req->url->clone ) } q{GET did not die};
        my $mock_result = [ split /\n/, $tx->res->text ];
        is scalar @{$mock_result}, scalar @{$result}, q{Result counts match};
        for ( 0 .. $#{$result} ) {
            isnt $mock_result->[$_], $result->[$_], qq{Result $_ does NOT match};
        }
    }
};

done_testing;