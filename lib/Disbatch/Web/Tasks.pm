package Disbatch::Web::Tasks;

use 5.12.0;
use warnings;

use Disbatch::Web;	# exports: parse_params send_json_options template
use Limper::SendJSON;
use Limper;
use MongoDB::OID 1.0.4;
use Safe::Isa;
use Time::Moment;
use Try::Tiny;

my $disbatch;

sub init {
    (my $self, $disbatch, my $args) = @_;
}

sub deserialize_oid {
    my ($object) = @_;
    if (ref $object eq 'HASH') {
        return MongoDB::OID->new(value => $object->{'$oid'}) if exists $object->{'$oid'};
        $object->{$_} = deserialize_oid($object->{$_}) for keys %$object;
    } elsif (ref $object eq 'ARRAY') {
        $_ = deserialize_oid($_) for @$object;
    }
    $object;
}

# see https://metacpan.org/pod/MongoDB::Collection#find
post '/tasks/search' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;

    my $LIMIT = 100;

    $params->{filter} //= {};
    $params->{options} //= {};
    $params->{count} //= 0;
    $params->{terse} //= 1;
    $params->{pretty} //= 0;
    unless (ref $params->{filter} eq 'HASH' and ref $params->{options} eq 'HASH') {
        status 400;
        return send_json { error => 'filter and options must be name/value objects' }, send_json_options;
    }
    $params->{options}{limit} //= $LIMIT;
    if ($params->{options}{limit} > $LIMIT) {
        status 400;
        return send_json { error => "limit cannot exceed $LIMIT" }, send_json_options;
    }

    $params->{filter}{queue} = { '$oid' => $params->{filter}{queue} } if defined $params->{filter}{queue} and !ref $params->{filter}{queue};

    my $oid_error = try { $params->{filter} = deserialize_oid($params->{filter}); undef } catch { "Bad OID passed: $_" };
    if (defined $oid_error) {
        Limper::warning $oid_error;
        status 400;
        return send_json { error => $oid_error }, send_json_options;
    }

    # Turn value into a Time::Moment object if it looks like it includes milliseconds. Will break in the year 2286.
    for my $type (qw/ctime mtime/) {
        $params->{filter}{$type} = Time::Moment->from_epoch($params->{filter}{$type} / 1000) if ($params->{filter}{$type} // 0) > 9999999999;
    }

    if ($params->{count}) {
        my $count = try { $disbatch->tasks->count($params->{filter}) } catch { Limper::warning $_; $_; };
        if (ref $count) {
            status 400;
            return send_json { error => "$count" }, send_json_options;
        }
        return send_json { count => $count }, send_json_options;
    }
    my ($error, @tasks) = try { undef, $disbatch->tasks->find($params->{filter}, $params->{options})->all } catch { Limper::warning "Could not find tasks: $_"; $_ };
    if (defined $error) {
        Limper::warning $error;
        status 400;
        return send_json { error => $error }, send_json_options;
    }

    for my $task (@tasks) {
        for my $type (qw/stdout stderr/) {
            if ($params->{terse}) {
                $task->{$type} = '[terse mode]' if defined $task->{$type} and !$task->{$type}->$_isa('MongoDB::OID') and $task->{$type};
            } elsif ($task->{$type}->$_isa('MongoDB::OID')) {
                $task->{$type} = try { $disbatch->get_gfs($task->{$type}) } catch { Limper::warning "Could not get task $task->{_id} $type: $_"; $task->{$type} };
            }
        }
        for my $type (qw/ctime mtime/) {
            $task->{$type} = $task->{$type}->hires_epoch if ref $task->{$type} eq 'DateTime';
        }
    }

    send_json \@tasks, send_json_options, pretty => $params->{pretty};
};

post qr'^/tasks/(?<queue>[^/]+)$' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;
    unless (defined $params and ref $params eq 'ARRAY' and @$params and ! grep { ref $_ ne 'HASH' } @$params) {
        status 400;
        return send_json { error => 'params must be a JSON array of task params objects' }, send_json_options;
    }
    if (grep { keys $_ == 0 } @$params) {
        status 400;
        return send_json { error => 'params must be a JSON array of task params objects with key/value pairs' }, send_json_options;
    }

    my $queue_id = get_queue_oid($+{queue});
    unless (defined $queue_id) {
        status 400;
        return send_json { error => 'queue not found' }, send_json_options;
    }

    my $res = create_tasks($queue_id, $params);

    my $reponse = {
        ref $res => {%$res},
    };
    unless (@{$res->{inserted}}) {
        status 400;
        $reponse->{error} = 'Unknown error';
    }
    send_json $reponse, send_json_options;
};

post qr'^/tasks/(?<queue>.+?)/(?<collection>.+)$' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;
    # {"migration":"foo"}
    # {"migration":"document.migration","user1":"document.username"}
    unless (defined $params->{filter} and ref $params->{filter} eq 'HASH' and defined $params->{params} and ref $params->{params} eq 'HASH') {
        status 400;
        return send_json { error => 'filter and params required and must be name/value objects' }, send_json_options;
    }

    my $collection = $+{collection};
    my $queue_id = get_queue_oid($+{queue});
    unless (defined $queue_id) {
        status 400;
        return send_json { error => 'queue not found' }, send_json_options;
    }

    my @fields = grep /^document\./, values %{$params->{params}};
    my %fields = map { s/^document\.//; $_ => 1 } @fields;

    my $cursor = $disbatch->mongo->coll($collection)->find($params->{filter})->fields(\%fields);
    my @tasks;
    my $error;
    try {
        while (my $doc = $cursor->next) {
            my $task = { %{$params->{params}} };	# copy it
            for my $key (keys %$task) {
                if ($task->{$key} =~ /^document\./) {
                    for my $field (@fields) {
                        my $f = quotemeta $field;
                        if ($task->{$key} =~ /^document\.$f$/) {
                            $task->{$key} = $doc->{$field};
                        }
                    }
                }
            }
            push @tasks, $task;
        }
    } catch {
        Limper::warning "Could not iterate on collection $collection: $_";
        $error = "$_";
    };

    if (defined $error) {
        status 400;
        return send_json { error => $error }, send_json_options;
    }

    my $res = create_tasks($queue_id, \@tasks);	# doing 100k at once only take 12 seconds on my 13" rMBP

    my $reponse = {
        ref $res => {%$res},
    };
    unless (@{$res->{inserted}}) {
        status 400;
        $reponse->{error} = 'Unknown error';
    }
    send_json $reponse, send_json_options;
};

1;

=item POST /tasks/search

Parameters: C<< { "filter": filter, "options": options, "count": count, "terse": terse } >>

All parameters are optional.

C<filter> is a filter expression (query) object.

C<options> is an object of desired options to L<MongoDB::Collection#find>.

If not set, C<options.limit> will be C<100>. This will fail if you try to set it above C<100>.

C<count> is a boolean. Instead of an array of task documents, the count of task documents matching the query will be returned.

C<terse> is a boolean. If C<true>, the the GridFS id or C<"[terse mode]"> will be returned for C<stdout> and C<stderr> of each document.
If C<false>, the full content of C<stdout> and C<stderr> will be returned. Default is C<true>.

Returns: Array of task Objects or C<< { "count": $count } >> on success; C<< { "error": "filter and options must be name/value objects" } >>,
C<< { "error": "limit cannot exceed 100" } >>, or C<< { "error": "Bad OID passed: $error" } >> on input error;
or C<< { "error": "$error" } >> on count or search error.

Sets HTTP status to C<400> on error.

Note: replaces /search-tasks-json

=item POST /tasks/:queue

URL: C<:queue> is the C<_id> if it matches C</\A[0-9a-f]{24}\z/>, or C<name> if it does not.

Parameters: an array of task params objects

Returns: C<< { ref $res: Object } >> on success; C<< { "error": "params must be a JSON array of task params" } >>
or C<< { "error": "queue not found" } >> on input error;  or C<< { ref $res: Object, "error": "Unknown error" } >> on MongoDB error.

Sets HTTP status to C<400> on error.

Note: replaces /queue-create-tasks-json

=item POST /tasks/:queue/:collection

URL: C<:queue> is the C<_id> if it matches C</\A[0-9a-f]{24}\z/>, or C<name> if it does not. C<:collection> is a MongoDB collection name.

Parameters: C<< { "filter": filter, "params": params } >>

C<filter> is a filter expression (query) object for the C<:collection> collection.

C<params> is an object of task params. To insert a document value from a query into the params, prefix the desired key name with C<document.> as a value.

Returns: C<< { ref $res: Object } >> on success; C<< { "error": "filter and params required and must be name/value objects" } >>
or C<< { "error": "queue not found" } >> on input error; C<< { "error": "Could not iterate on collection $collection: $error" } >> on query error,
or C<< { ref $res: Object, "error": "Unknown error" } >> on MongoDB error.

Sets HTTP status to C<400> on error.

Note: replaces /queue-create-tasks-from-query-json
