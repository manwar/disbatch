package Disbatch::Web;

use 5.12.0;
use strict;
use warnings;

use Cpanel::JSON::XS;
use Data::Dumper;
use Disbatch;
use File::Slurp;
use Limper::SendFile;
use Limper::SendJSON;
use Limper;
use Log::Log4perl;
use MongoDB::OID 1.0.0;
use Safe::Isa;
use Time::Moment;
use Try::Tiny::Retry;
use URL::Encode qw/url_params_mixed/;

my $json = Cpanel::JSON::XS->new->utf8;
my $disbatch;

sub init {
    my $args = { @_ };
    $disbatch = Disbatch->new(class => 'Disbatch::Web', config_file => ($args->{config_file} // '/etc/disbatch/config.json'));
    $disbatch->load_config;
    public ($disbatch->{config}{web_root} // '/etc/disbatch/htdocs/');
}

sub parse_params {
    if ((request->{headers}{'content-type'} // '') eq 'application/x-www-form-urlencoded') {
        url_params_mixed(request->{body}, 1);
    } elsif ((request->{headers}{'content-type'} // '') eq 'application/json') {
        try { $json->decode(request->{body}) } catch { $_ };
    } elsif (request->{query}) {
        url_params_mixed(request->{query}, 1);
    }
}

################
#### NEW API ###
################

sub datetime_to_millisecond_epoch {
    int($_[0]->hires_epoch * 1000);
}

# will throw errors
sub get_nodes {
    my ($query) = @_;
    $query //= {};
    my @nodes = $disbatch->nodes->find($query)->sort({node => 1})->all;
    for my $node (@nodes) {
        $node->{id} = "$node->{_id}";
        $node->{timestamp} = datetime_to_millisecond_epoch($node->{timestamp}) if ref $node->{timestamp} eq 'DateTime';
    }
    \@nodes;
}

=item GET /nodes

Parameters: none.

Returns an array of node objects defined, with C<id> the stringified C<_id>.

=cut

get '/nodes' => sub {
    undef $disbatch->{mongo};
    my $nodes = try { get_nodes } catch { status 400; "Could not get current nodes: $_" };
    if (status == 400) {
        Limper::warning $nodes;
        return send_json { success => 0, error => $nodes };
    }
    send_json { success => 1, nodes => $nodes }, convert_blessed => 1;
};

=item GET /nodes/:node

URL: C<:node> is the C<_id> if it matches C</\A[0-9a-f]{24}\z/>, or C<node> name if it does not.

Parameters: none.

Returns an array of node objects defined, with C<id> the stringified C<_id>.

=cut

get qr'^/nodes/(?<node>.+)' => sub {
    undef $disbatch->{mongo};
    my $query = try { {_id => MongoDB::OID->new(value => $+{node})} } catch { {node => $+{node}} };
    my $node = try { get_nodes($query) } catch { status 400; "Could not get node $+{node}: $_" };
    if (status == 400) {
        Limper::warning $node;
        return send_json { success => 0, error => $node };
    }
    send_json { success => 1, node => $node->[0] }, convert_blessed => 1;
};

=item POST /nodes/:node

URL: C<:node> is the C<_id> if it matches C</\A[0-9a-f]{24}\z/>, or C<node> name if it does not.

Parameters: C<< { "maxthreads": maxthreads } >>

"maxthreads" is a non-negative integer or null

Returns C<< { "success": 1, ref $res: Object } >> or C<< { "success": 0, ref $res: Object, "error": error_string_or_reponse_object } >>

=cut

#  postJSON('/nodes/' + row.rowId , { maxthreads: newValue}, loadQueues);
post qr'^/nodes/(?<node>.+)' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;

    unless (keys %$params) {
        status 400;
        return send_json {success => 0, error => 'No params'};
    }
    my @valid_params = qw/maxthreads/;
    for my $param (keys %$params) {
        unless (grep $_ eq $param, @valid_params) {
            status 400;
            return send_json { success => 0, error => 'Invalid param', param => $param};
        }
    }
    if (exists $params->{maxthreads} and defined $params->{maxthreads} and $params->{maxthreads} !~ /^\d+$/) {
        status 400;
        return send_json {success => 0, error => 'maxthreads must be a non-negative integer or null'};
    }
    my $query = try { {_id => MongoDB::OID->new(value => $+{node})} } catch { {node => $+{node}} };
    my $res = try {
        $disbatch->nodes->update_one($query, {'$set' => $params});
    } catch {
        Limper::warning "Could not update node $+{node}: $_";
        $_;
    };
    my $reponse = {
        success => $res->{matched_count} == 1 ? 1 : 0,
        ref $res => {%$res},
    };
    unless ($reponse->{success}) {
        status 400;
        if ($res->$_isa('MongoDB::UpdateResult')) {
            $reponse->{error} = $reponse->{'MongoDB::UpdateResult'};
        } else {
            $reponse->{error} = "$res";
        }
    }
    send_json $reponse;
};

=item GET /plugins

Parameters: none.

Returns an array of allowed plugin names.

Note: replaces /queue-prototypes-json

=cut

# This is needed at least to create queues in the web interface.
get '/plugins' => sub {
    send_json $disbatch->{config}{plugins};
};

=item GET /queues

Parameters: none.

Returns array of queues.

Each item has the following keys: id, plugin, name, threads, queued, running, completed

Note: replaces /scheduler-json

=cut

get '/queues' => sub {
    undef $disbatch->{mongo};
    send_json { success => 1, queues => $disbatch->scheduler_report };
};

sub map_plugins {
    my %plugins = map { $_ => 1 } @{$disbatch->{config}{plugins}};
    \%plugins;
}

=item POST /queues

Parameters: C<< { "name": name, "type": type } >>

"type" is a plugin value.

Returns: C<< { FIXME } >>

Note: replaces /start-queue-json

=cut

post '/queues' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;
    unless (defined $params->{name} and defined $params->{plugin}) {
        status 400;
        return send_json { success => 0, error => 'name and plugin required' };
    }
    my @valid_params = qw/threads name plugin/;
    for my $param (keys %$params) {
        unless (grep $_ eq $param, @valid_params) {
            status 400;
            return send_json { success => 0, error => 'Invalid param', param => $param};
        }
    }
    unless (map_plugins->{$params->{plugin}}) {
        status 400;
        return send_json { success => 0, error => 'unknown plugin', plugin => $params->{plugin} };
    }

    my $res = try { $disbatch->queues->insert_one($params) } catch { Limper::warning "Could not create queue $params->{name}: $_"; $_ };
    my $reponse = {
        success => defined $res->{inserted_id} ? 1 : 0,
        ref $res => {%$res},
        id => $res->{inserted_id},
    };
    unless ($reponse->{success}) {
        status 400;
        $reponse->{error} = "$res";
    }
    send_json $reponse, convert_blessed => 1;
};

=item POST /queues/:queue

URL: C<:queue> is the C<_id> if it matches C</\A[0-9a-f]{24}\z/>, or C<name> if it does not.

Parameters: C<< { "threads": threads, "name": name, "plugin": plugin } >>

C<threads> must be a non-negative integer, C<plugin> must be defined in the config file, C<name> must be a string.
Only one is required, but any combination is allowed.

Returns C<< { "success": 1, ref $res: Object } >> or C<< { "success": 0, "error": error } >>

Note: replaces /set-queue-attr-json

=cut

post qr'^/queues/(?<queue>.+)$' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;
    my @valid_params = qw/threads name plugin/;

    unless (keys %$params) {
        status 400;
        return send_json {success => 0, error => 'no params'};
    }
    for my $param (keys %$params) {
        unless (grep $_ eq $param, @valid_params) {
            status 400;
            return send_json { success => 0, error => 'unknown param', param => $param};
        }
    }
    if (exists $params->{plugin} and !map_plugins()->{$params->{plugin}}) {
        status 400;
        return send_json { success => 0, error => 'unknown plugin', plugin => $params->{plugin} };
    }
    if (exists $params->{threads} and $params->{threads} !~ /^\d+$/) {
        status 400;
        return send_json {success => 0, error => 'threads must be a non-negative integer'};
    }
    if (exists $params->{name} and (ref $params->{name} or !defined $params->{name})){
        status 400;
        return send_json {success => 0, error => 'name must be a string'};
    }

    my $query = try { {_id => MongoDB::OID->new(value => $+{queue})} } catch { {name => $+{queue}} };
    my $res = try {
        $disbatch->queues->update_one($query, {'$set' => $params});
    } catch {
        Limper::warning "Could not update queue $+{queue}: $_";
        $_;
    };
    my $reponse = {
        success => $res->{matched_count} == 1 ? 1 : 0,
        ref $res => {%$res},
    };
    unless ($reponse->{success}) {
        status 400;
        $reponse->{error} = "$res";
    }
    send_json $reponse;
};

=item DELETE /queues/:queue

URL: C<:queue> is the C<_id> if it matches C</\A[0-9a-f]{24}\z/>, or C<name> if it does not.

Parameters: none

Deletes the specified queue.

Returns: C<< FIXME >>

Note: replaces /delete-queue-json
=cut

del qr'^/queues/(?<queue>.+)$' => sub {
    undef $disbatch->{mongo};

    my $query = try { {_id => MongoDB::OID->new(value => $+{queue})} } catch { {name => $+{queue}} };
    my $res = try { $disbatch->queues->delete_one($query) } catch { Limper::warning "Could not delete queue '$+{queue}': $_"; $_ };
    my $reponse = {
        success => $res->{deleted_count} ? 1 : 0,
        ref $res => {%$res},
    };
    unless ($reponse->{success}) {
        status 400;
        $reponse->{error} = "$res";
    }
    send_json $reponse;
};

# returns an MongoDB::OID object of either a simple string representation of the OID or a queue name, or undef if queue not found/valid
sub get_queue_oid {
    my ($queue) = @_;
    my $queue_id = try {
        MongoDB::OID->new(value => $queue);
    } catch {
        my $q = try { $disbatch->queues->find_one({name => $queue}) } catch { Limper::warning "Could not find queue $queue: $_"; undef };
        defined $q ? $q->{_id} : undef;
    };
}

# creates a task for given queue _id and params, returning task _id
sub create_tasks {
    my ($queue_id, $tasks) = @_;

    my @tasks = map {
        queue      => $queue_id,
        status     => -2,
        stdout     => undef,
        stderr     => undef,
        node       => undef,
        params     => $_,
        ctime      => Time::Moment->now_utc,
        mtime      => Time::Moment->now_utc,
    }, @$tasks;

    my $res = try { $disbatch->tasks->insert_many(\@tasks) } catch { Limper::warning "Could not create tasks: $_"; $_ };
    $res;
}

=item POST /tasks/:queue

URL: C<:queue> is the C<_id> if it matches C</\A[0-9a-f]{24}\z/>, or C<name> if it does not.

Parameters: an array of task params objects

Returns: C<< { FIXME } >>

Note: replaces /queue-create-tasks-json

=cut

post qr'^/tasks/(?<queue>.+)$' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;
    unless (defined $params and ref $params eq 'ARRAY') {
        status 400;
        return send_json { success => 0, error => 'params must be a JSON array of task params' };
    }

    my $queue_id = get_queue_oid($+{queue});
    unless (defined $queue_id) {
        status 400;
        return send_json { success => 0, error => 'queue not found' };
    }

    my $res = create_tasks($queue_id, $params);

    my $reponse = {
        success => @{$res->{inserted}} ? 1 : 0,
        ref $res => {%$res},
    };
    unless ($reponse->{success}) {
        status 400;
        $reponse->{error} = 'Unknown error';
    }
    send_json $reponse, convert_blessed => 1;
};

=item POST /tasks/:queue/:collection

URL: C<:queue> is the C<_id> if it matches C</\A[0-9a-f]{24}\z/>, or C<name> if it does not. C<:collection> is a MongoDB collection name.

Parameters: C<< { "query": query, "params": params } >>

C<query> is a query object for the C<:collection> collection.

C<params> is an object of task params. To insert a document value from a query into the params, prefix the desired key name with C<document.> as a value.

Returns: C<< { FIXME } >>

Note: replaces /queue-create-tasks-from-query-json

=cut

post qr'^/tasks/(?<queue>.+?)/(?<collection>.+)$' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;
    # {"migration":"foo"}
    # {"migration":"document.migration","user1":"document.username"}
    unless (defined $params->{query} and ref $params->{query} eq 'HASH' and defined $params->{params} and ref $params->{params} eq 'HASH') {
        status 400;
        return send_json { success => 0, error => 'query and params required and must be name/value objects' };
    }

    my $queue_id = get_queue_oid($+{queue});
    unless (defined $queue_id) {
        status 400;
        return send_json { success => 0, error => 'queue not found' };
    }

    my @fields = grep /^document\./, values %{$params->{params}};
    my %fields = map { s/^document\.//; $_ => 1 } @fields;

    my $cursor = $disbatch->mongo->coll($+{collection})->find($params->{query})->fields(\%fields);
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
        Limper::warning "Could not iterate on collection $+{collection}: $_";
        $error = "$_";
    };

    return send_json { success => 0, error => $error } if defined $error;

    my $res = create_tasks($queue_id, \@tasks);	# doing 100k at once only take 12 seconds on my 13" rMBP

    my $reponse = {
        success => @{$res->{inserted}} ? 1 : 0,
        ref $res => {%$res},
    };
    unless ($reponse->{success}) {
        status 400;
        $reponse->{error} = 'Unknown error';
    }
    send_json $reponse, convert_blessed => 1;
};

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

=item POST /tasks/search

Parameters: C<< { "filter": filter, "options": options, "count": count, "terse": terse } >>

All parameters are optional.

C<filter> is a query object.

C<options> is an object of desired options to L<MongoDB::Collection#find>.

If not set, C<options.limit> will be C<100>. This will fail if you try to set it above C<100>.

C<count> is a boolean. Instead of an array of task documents, the count of task documents matching the query will be returned.

C<terse> is a boolean. If C<true>, the the GridFS id or C<"[terse mode]"> will be returned for C<stdout> and C<stderr>.
If C<false>, the content of C<stdout> and C<stderr> will be returned. Default is C<true>.

Returns: C<< { FIXME } >>

Note: replaces /search-tasks-json

=cut

# FIXME: I don't like this URL. And should it be a POST?
# see https://metacpan.org/pod/MongoDB::Collection#find
post '/tasks/search' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;

    my $LIMIT = 100;

    $params->{filter} //= {};
    $params->{options} //= {};
    $params->{count} // 0;
    $params->{terse} // 1;
    unless (ref $params->{filter} eq 'HASH' and ref $params->{options} eq 'HASH') {
        status 400;
        return send_json { success => 0, error => 'filter and options must be name/value objects' };
    }
    $params->{options}{limit} //= $LIMIT;
    if ($params->{options}{limit} > $LIMIT) {
        status 400;
        return send_json { success => 0, error => "limit cannot exceed $LIMIT" };
    }

    my $oid_error = try { $params->{filter} = deserialize_oid($params->{filter}); undef } catch { "Bad OID passed: $_" };
    if (defined $oid_error) {
        Limper::warning $oid_error;
        status 400;
        return send_json { success => 0, error => $oid_error };
    }

    # Turn value into a Time::Moment object if it looks like it includes milliseconds. Will break in the year 2286.
    for my $type (qw/ctime mtime/) {
        $params->{filter}{$type} = Time::Moment->from_epoch($params->{filter}{$type} / 1000) if ($params->{filter}{$type} // 0) > 9999999999;
    }

    if ($params->{count}) {
        my $count = try { $disbatch->tasks->count($params->{filter}) } catch { Limper::warning $_; $_; };
        if (ref $count) {
            status 400;
            return send_json { success => 0, error => "$count" };
        }
        return send_json { success => 1, count => $count };
    }
    my ($error, @tasks) = try { undef, $disbatch->tasks->find($params->{filter}, $params->{options})->all } catch { Limper::warning "Could not find tasks: $_"; $_ };
    if (defined $error) {
        Limper::warning $error;
        status 400;
        return send_json { success => 0, error => $error };
    }

    for my $task (@tasks) {
        for my $type (qw/stdout stderr/) {
            if ($params->{terse}) {
                $task->{$type} = '[terse mode]' unless $task->{$type}->$_isa('MongoDB::OID');
            } elsif ($task->{$type}->$_isa('MongoDB::OID')) {
                $task->{$type} = try { $disbatch->get_gfs($task->{$type}) } catch { Limper::warning "Could not get task $task->{_id} $type: $_"; $task->{$type} };
            }
        }
        for my $type (qw/ctime mtime/) {
            $task->{$type} = $task->{$type}->hires_epoch if ref $task->{$type} eq 'DateTime';
        }
    }

    send_json { success => 1, tasks => \@tasks }, convert_blessed => 1;
};

get '/' => sub {
    send_file '/index.html';
};

get qr{^/} => sub {
    send_file request->{path};        # sends request->{uri} by default
};

################
#### OLD API ###
################

get '/scheduler-json' => sub {
    undef $disbatch->{mongo};
    send_json $disbatch->scheduler_report;
};

post '/set-queue-attr-json' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;
    my @valid_attributes = qw/threads/;
    unless (grep $_ eq $params->{attr}, @valid_attributes) {
        status 400;
        return send_json { success => 0, error => 'Invalid attr'};
    }
    unless (defined $params->{value}) {
        status 400;
        return send_json {success => 0, error => 'You must supply a value'};
    }
    unless (defined $params->{queueid}) {
        status 400;
        return send_json {success => 0, error => 'You must supply a queueid'};
    }
    my $res = try {
        $disbatch->queues->update_one({_id => MongoDB::OID->new(value => $params->{queueid})}, {'$set' => { $params->{attr} => $params->{value} }});
    } catch {
        Limper::warning "Could not update queue $params->{queueid}: $_";
        $_;
    };
    my $reponse = {
        success => $res->{matched_count} == 1 ? 1 : 0,
        ref $res => {%$res},
    };
    unless ($reponse->{success}) {
        status 400;
        $reponse->{error} = "$res";
    }
    send_json $reponse;
};

sub get_plugins {
    my @plugins = try { $disbatch->queues->distinct('plugin')->all } catch { Limper::warning "Could not get current plugins: $_"; () };
    my $plugins = $disbatch->{config}{plugins} // [];
    my %plugins = map { $_ => $_ } @plugins, @$plugins;
    \%plugins;
}

post '/start-queue-json' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;
    unless (defined $params->{type} and defined $params->{name}) {
        status 400;
        return send_json [ 0, 'type and name required'];
    }

    unless (get_plugins->{$params->{type}}) {
        status 400;
        return send_json [ 0, 'unknown type'];
    }

    my $queue = { plugin => $params->{type}, name => $params->{name} };
    my $res = try { $disbatch->queues->insert_one($queue) } catch { Limper::warning "Could not create queue $params->{name}: $_"; $_ };
    my $reponse = {
        success => defined $res->{inserted_id} ? 1 : 0,
        ref $res => {%$res},
    };
    unless ($reponse->{success}) {
        status 400;
        $reponse->{error} = "$res";
    }
    send_json [ $reponse->{success}, $reponse->{ref $res}{inserted_id}, $reponse ], convert_blessed => 1;
};

post '/delete-queue-json' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;
    unless (defined $params->{id}) {
        status 400;
        return send_json [ 0, 'id required'];
    }

    my $res = try { $disbatch->queues->delete_one({_id => MongoDB::OID->new(value => $params->{id})}) } catch { Limper::warning "Could not delete queue $params->{id}: $_"; $_ };
    my $reponse = {
        success => $res->{deleted_count} ? 1 : 0,
        ref $res => {%$res},
    };
    unless ($reponse->{success}) {
        status 400;
        $reponse->{error} = "$res";
    }
    send_json [ $reponse->{success}, $reponse ];
};

# This is needed at least to create queues in the web interface (just the keys).
get '/queue-prototypes-json' => sub {
    undef $disbatch->{mongo};
    send_json get_plugins;
};

sub get_queue_oid_old {
    my ($queue) = @_;
    my $queue_id = try {
        MongoDB::OID->new(value => $queue);
    } catch {
        my $q = try { $disbatch->queues->find_one({name => $queue}) } catch { Limper::warning "Could not find queue $queue: $_"; undef };
        defined $q ? $q->{_id} : undef;
    };
}

# creates a task for given queue _id and params, returning task _id
sub create_tasks_old {
    my ($queue_id, $tasks) = @_;

    my @tasks = map {
        queue      => $queue_id,
        status     => -2,
        stdout     => undef,
        stderr     => undef,
        node       => undef,
        params     => $_,
        ctime      => Time::Moment->now_utc,
        mtime      => Time::Moment->now_utc,
    }, @$tasks;

    my $res = try { $disbatch->tasks->insert_many(\@tasks) } catch { Limper::warning "Could not create tasks: $_"; $_ };
    $res;
}

post '/queue-create-tasks-json' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;
    unless (defined $params->{queueid} and defined $params->{object}) {
        status 400;
        return send_json [ 0, 'queueid and object required'];
    }

    my $tasks = try { ref $params->{object} ? $params->{object} : $json->decode($params->{object}) } catch { $_ };
    return send_json [ 0, $tasks ] unless ref $tasks;
    return send_json [ 0, 'object param must be a JSON array' ] unless ref $tasks eq 'ARRAY';

    my $queue_id = get_queue_oid_old($params->{queueid});
    return send_json [ 0, 'Queue not found' ] unless defined $queue_id;

    my $res = create_tasks_old($queue_id, $tasks);

    my $reponse = {
        success => @{$res->{inserted}} ? 1 : 0,
        ref $res => {%$res},
    };
    unless ($reponse->{success}) {
        status 400;
        $reponse->{error} = 'Unknown error';
    }
    send_json [ $reponse->{success}, scalar @{$res->{inserted}}, @{$res->{inserted}}, $reponse ], convert_blessed => 1;
};

post '/queue-create-tasks-from-query-json' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;
    unless (defined $params->{queueid} and defined $params->{collection} and defined $params->{jsonfilter} and defined $params->{params}) {
        status 400;
        return send_json [ 0, 'queueid, collection, jsonfilter, and params required'];
    }

    my $filter = try { ref $params->{jsonfilter} ? $params->{jsonfilter} : $json->decode($params->{jsonfilter}) } catch { $_ };	# {"migration":"foo"}
    return send_json [ 0, $filter ] unless ref $filter;

    my $task_params = try { ref $params->{params} ? $params->{params} : $json->decode($params->{params}) } catch { $_ };	# {"migration":"document.migration","user1":"document.username"}
    return send_json [ 0, $task_params ] unless ref $task_params;

    my $queue_id = get_queue_oid_old($params->{queueid});
    return send_json [ 0, 'Queue not found' ] unless defined $queue_id;

    my @fields = grep /^document\./, values %$task_params;
    my %fields = map { s/^document\.//; $_ => 1 } @fields;

    my $cursor = $disbatch->mongo->coll($params->{collection})->find($filter)->fields(\%fields);
    my @tasks;
    my $error;
    try {
        while (my $object = $cursor->next) {
            my $task = { %$task_params };
            for my $key (keys %$task) {
                if ($task->{$key} =~ /^document\./) {
                    for my $field (@fields) {
                        my $f = quotemeta $field;
                        if ($task->{$key} =~ /^document\.$f$/) {
                            $task->{$key} = $object->{$field};
                        }
                    }
                }
            }
            push @tasks, $task;
        }
    } catch {
        Limper::warning "Could not iterate on collection $params->{collection}: $_";
        $error = "$_";
    };

    return send_json [ 0, $error ] if defined $error;

    my $res = create_tasks_old($queue_id, \@tasks);	# doing 100k at once only take 12 seconds on my 13" rMBP

    my $reponse = {
        success => @{$res->{inserted}} ? 1 : 0,
        ref $res => {%$res},
    };
    unless ($reponse->{success}) {
        status 400;
        $reponse->{error} = 'Unknown error';
    }
    send_json [ $reponse->{success}, scalar @{$res->{inserted}} ];
#    send_json [ $reponse->{success}, scalar @{$res->{inserted}}, @{$res->{inserted}}, $reponse ], convert_blessed => 1;
};

post '/search-tasks-json' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;
    #unless (defined $params->{queue} and defined $params->{filter}) {
    #    status 400;
    #    return send_json [ 0, 'queue and filter required'];
    #}

    $params->{filter} //= {};
    my $filter = try { ref $params->{filter} ? $params->{filter} : $json->decode($params->{filter}) } catch { $_ };
    return send_json [ 0, $params->{json} ? $filter : 'JSON object required for filter' ] unless ref $filter eq 'HASH';

    my $attrs = {};
    $attrs->{limit} = $params->{limit} if $params->{limit};
    $attrs->{skip}  = $params->{skip}  if $params->{skip};

    my $error;
    try {
        $filter->{queue} = MongoDB::OID->new(value => $params->{queue}) if $params->{queue};
        $filter->{_id} = MongoDB::OID->new(value => delete $filter->{id}) if $filter->{id};
    } catch {
        $error = "$_";
        Limper::warning "Bad OID passed: $error";
    };
    return send_json [ 0, $error ] if defined $error;
    $filter->{status} = int $filter->{status} if defined $filter->{status};

    if ($params->{count}) {
        my $count = try { $disbatch->tasks->count($filter) } catch { Limper::warning $_; $_; };
        return send_json [ 0, "$count" ] if ref $count;
        return send_json [ 1, $count ];
    }
    my @tasks = try { $disbatch->tasks->find($filter, $attrs)->all } catch { Limper::warning "Could not find tasks: $_"; () };

    for my $task (@tasks) {
        if ($params->{terse}) {
            $task->{stdout} = '[terse mode]' unless $task->{stdout}->$_isa('MongoDB::OID');
            $task->{stderr} = '[terse mode]' unless $task->{stderr}->$_isa('MongoDB::OID');
        } else {
            $task->{stdout} = try { $disbatch->get_gfs($task->{stdout}) } catch { Limper::warning "Could not get task $task->{_id} stdout: $_"; $task->{stdout} } if $task->{stdout}->$_isa('MongoDB::OID');
            $task->{stderr} = try { $disbatch->get_gfs($task->{stderr}) } catch { Limper::warning "Could not get task $task->{_id} stderr: $_"; $task->{stderr} } if $task->{stderr}->$_isa('MongoDB::OID');
        }

        for my $type (qw/ctime mtime/) {
            if ($task->{$type}) {
                if (ref $task->{$type}) {
                    if (ref $task->{$type} eq 'Time::Moment' or ref $task->{$type} eq 'DateTime') {
                        $task->{"${type}_str"} = "$task->{$type}";
                        $task->{$type} = $task->{$type}->epoch;
                    } else {
                        # Unknown ref, force to string
                        $task->{"${type}_str"} = "$task->{$type}";
                        $task->{$type} = undef;
                    }
                } else {
                    try {
                        my $dt = DateTime->from_epoch(epoch => $task->{$type});
                        $task->{"${type}_str"} = "$dt";
                    } catch {
                        $task->{"${type}_str"} = "$task->{$type}";
                        $task->{$type} = undef;
                    };
                }
            }
        }
    }

    send_json \@tasks, convert_blessed => 1;
};

1;

__END__

=encoding utf8

=head1 NAME

Disbatch::Web - Disbatch Command Interface (JSON REST API and web browser interface to Disbatch).

=head1 SUBROUTINES

=over 2

=item init(config_file => $config_file)

Parameters: path to the Disbatch config file. Default is C</etc/disbatch/config.json>.

Initializes the settings for the web server.

Returns nothing.

=item parse_params

Parameters: none

Parses request parameters in the following order:

* from the request body if the Content-Type is C<application/x-www-form-urlencoded>

* from the request body if the Content-Type is C<application/json>

* from the request query otherwise

Returns a C<HASH> of the parsed request parameters.

=item get_nodes

Parameters: none

Returns an array of node objects defined, with C<timestamp> stringified and C<id> the stringified C<_id>.

=item get_plugins

Parameters: none

Returns a C<HASH> of defined queues plugins and any defined C<config.plugins>, where values match the keys.

=item get_queue_oid($queue)

Parameters: Queue ID as a string, or queue name.

Returns a C<MongoDB::OID> object representing this queue's _id.

=item create_tasks($queue_id, $tasks)

Parameters: C<MongoDB::OID> object of the queue _id, C<ARRAY> of task params.

Creates one queued task document for the given queue _id per C<$tasks> entry. Each C<$task> entry becomes the value of the C<params> field of the document.

Returns: the repsonse object from a C<MongoDB::Collection#insert_many> request.

=back

=head1 JSON ROUTES

=over 2

=back

=head1 BROWSER ROUTES

=over 2

=item GET /

Returns the contents of "/index.html" – the queue browser page.

=item GET qr{^/}

Returns the contents of the request path.

=back

=head1 SEE ALSO

L<Disbatch>

L<Disbatch::Roles>

L<Disbatch::Plugin::Demo>

L<disbatchd>

L<disbatch.pl>

L<task_runner>

L<disbatch-create-users>

=head1 AUTHORS

Ashley Willis <awillis@synacor.com>

Matt Busigin

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2016 by Ashley Willis.

This is free software, licensed under:

  The Apache License, Version 2.0, January 2004
