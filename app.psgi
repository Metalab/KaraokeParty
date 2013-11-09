use 5.010;
use strictures;
no warnings 'experimental::smartmatch';
use Config::Tiny qw();
use DateTime qw();
use DateTime::Format::Duration qw();
require DateTime::Format::Pg;
require DBIx::Class::InflateColumn::DateTime;
use DBIx::Class::Schema::Loader qw();
use Encode qw(decode encode);
use MIME::Base64 qw();
use Template qw();
use Web::Request qw();

my %config = %{ Config::Tiny->read('config.ini')->{_} };
DBIx::Class::Schema::Loader->loader_options(
    components => 'InflateColumn::DateTime',
    naming => {ALL => 'preserve'},
);
my $schema = DBIx::Class::Schema::Loader->connect(
    "dbi:Pg:dbname=$config{KARAOKEPARTY_DB_NAME};port=$config{KARAOKEPARTY_DB_PORT}",
    undef, undef, { pg_enable_utf8 => 1 }
);
my $songs = $schema->resultset('Songs');
my $queue = $schema->resultset('Queue');
my $tt = Template->new({ ENCODING => 'UTF-8' });

my $app = sub {
    my ($env) = @_;
    my $req = Web::Request->new_from_env($env);
    for ($req->path) {
        when ('/') {
            my @q = $queue->search(
                { visible => 1 }, { order_by => 'submitted' }
            )->all;
            my $waiting_time;
            if ($queue->search->count > 0) {
                my $time = DateTime->now;
                $time->set_time_zone($config{TZ});
                my $first_song_when = $queue->search(
                    undef, { order_by => 'submitted' }
                )->first->submitted;
                $waiting_time =
                    $time->clone->subtract_datetime_absolute($first_song_when)->seconds
                    / ($queue->search({ visible => 0 })->count || 1); # /
                $waiting_time = 240 if $waiting_time < 240;
                for my $i (0..$#q) {
                    $q[$i]->add_column('eta');
                    $q[$i]->eta($time->clone->add(seconds => $waiting_time * $i));
                }
            }
            my $out;
            $tt->process(
                'root.tt',
                {
                    songs => [$songs->all],
                    queue => [@q],
                    $waiting_time
                        ? (waiting_time => sprintf('%dmin %ds', $waiting_time / 60, $waiting_time % 60))
                        : ()
                },
                \$out,
            );
            return $req->new_response(
                status => 200,
                content => encode('UTF-8', $out),
                content_type => 'application/xhtml+xml; charset=UTF-8',
            )->finalize;
        }
        when ('/add') {
            my %p = %{ $req->body_parameters };
            my $nick = decode 'UTF-8', delete $p{nickname};
            my @temp = grep /^id/, keys { %p };
            my $id = shift @temp;
            $id =~ s/^id//;
            $queue->create({
                nickname => $nick,
                song => $id,
            });
            return $req->new_response(
                status => 301,
                content => q(),
                headers => [Location => '/']
            )->finalize;
        }
        when ('/moderation') {
            my $auth = auth($env, $req);
            return $auth if $auth;
            my $out;
            $tt->process(
                'moderation.tt',
                {
                    songs => [$songs->all],
                    queue => [$queue->search(
                        { exists $req->parameters->{all} ? () : (visible => 1)},
                        { order_by => 'submitted' }
                    )->all
                    ],
                },
                \$out,
            );
            return $req->new_response(
                status => 200,
                content => encode('UTF-8', $out),
                content_type => 'application/xhtml+xml; charset=UTF-8',
            )->finalize;
        }
        when ('/moderate') {
            return $req->new_response(
                status => 405,
                content => ['only POST allowed on this resource'],
                headers => [Allow => 'POST'],
                content_type => 'text/plain',
            )->finalize unless 'POST' eq $req->method;
            my $auth = auth($env, $req);
            return $auth if $auth;
            my %p = %{ $req->body_parameters };
            my $id = delete $p{id};
            $p{visible} = $p{visible} ? 1 : 0;
            $p{nickname} = decode 'UTF-8', $p{nickname};
            $queue->find($id)->update({ %p });
            return $req->new_response(
                status => 301,
                content => q(),
                headers => [Location => '/moderation'],
            )->finalize;
        }
        default {
            return $req->new_response(
                status => 404,
                content => 'not found',
                content_type => 'text/plain',
            )->finalize;
        }
    }
};

sub auth {
    my ($env, $req) = @_;
    my ($authorized) = ($env->{HTTP_AUTHORIZATION} // '') =~ /^Basic (.*)$/i;
    my ($user, $pass) = split /:/, (MIME::Base64::decode($authorized // '') || ":"), 2; # /
    unless ($config{KARAOKEPARTY_MODERATION_AUTH} eq "$user:$pass") {
        return $req->new_response(
            status => 401,
            content => 'Authentication required',
            content_type => 'text/plain; charset=UTF-8',
            headers => ['WWW-Authenticate' => 'Basic realm="restricted area"'] ,
        )->finalize;
    }
    return;
}

$app;
