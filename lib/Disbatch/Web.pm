package Disbatch::Web;

use 5.12.0;
use strict;
use warnings;

use Clone qw/clone/;
use Cpanel::JSON::XS;
use Data::Dumper;
use Disbatch;
use Disbatch::Web::Query;
use Exporter qw/ import /;
use File::Slurp;
use Limper::SendFile;	# needed for public()
use Limper::SendJSON;
use Limper;
use MongoDB::OID 1.0.4;
use Safe::Isa;
use Template;
use Time::Moment;
use Try::Tiny::Retry;
use URL::Encode qw/url_params_mixed/;

our @EXPORT = qw/ parse_params send_json_options template /;

my $oid_keys = [ qw/ queue / ];	# NOTE: in addition to _id
my $util = Disbatch::Web::Query->new();	# query()

sub send_json_options { allow_blessed => 1, canonical => 1, convert_blessed => 1 }

# the following options should be compatible with previous Dancer usage:
my $tt = Template->new(ANYCASE => 1, ABSOLUTE => 1, ENCODING => 'utf8', INCLUDE_PATH => 'views', START_TAG => '\[%', END_TAG => '%\]', WRAPPER => 'layouts/main.tt');

# this should be compatible with Dancer's template(), except we do not support the optional settings (third value), and it was unused by RemoteControl
sub template {
    my ($template, $params) = @_;
    my $output = '';
    $params->{perl_version} = $];
    $params->{limper_version} = $Limper::VERSION;
    $params->{request} = request;
    $tt->process($template, $params, \$output) || die $tt->error();
    headers 'Content-Type' => 'text/html';
    $output;
}

my $disbatch;

sub init {
    my $args = { @_ };
    $disbatch = Disbatch->new(class => 'Disbatch::Web', config_file => ($args->{config_file} // '/etc/disbatch/config.json'));
    $disbatch->load_config;
    public ($disbatch->{config}{web_root} // '/etc/disbatch/htdocs/');
    for my $plugin (keys %{$disbatch->{config}{web_extensions} // {}}) {
        if ($plugin !~ /^[\w:]+$/) {
            $disbatch->logger->error("Illegal plugin value: $plugin, ignored");
        } elsif (eval "require $plugin") {
            $disbatch->logger->info("$plugin found and loaded");
            $plugin->init($disbatch, $disbatch->{config}{web_extensions}{$plugin}) if $plugin->can('init');
        } else {
            $disbatch->logger->warn("Could not load $plugin, ignored");
        }
    }
    require Disbatch::Web::Files;	# this has a catch-all to send any matching file in the public root directory, so must be loaded last.
}

sub parse_params {
    my $params = {};
    if ((request->{headers}{'content-type'} // '') eq 'application/x-www-form-urlencoded') {
        $params = url_params_mixed(request->{body}, 1);
    } elsif ((request->{headers}{'content-type'} // '') eq 'application/json') {
        $params = try { Cpanel::JSON::XS->new->utf8->decode(request->{body}) } catch { $_ };
    } elsif (request->{query}) {
        $params = url_params_mixed(request->{query}, 1);
    }
    my $options = { map { $_ => delete $params->{$_} } grep { /^\./ } keys %$params } if ref $params eq 'HASH';	# put fields starting with '.' into their own HASH
    # NOTE: $options may contain: .limit .skip .count .pretty .terse .epoch
    wantarray ? ($params, $options) : $params;
}

sub parse_accept {
    +{ map { @_ = split(/;q=/, $_); $_[0] => $_[1] // 1 } split /,\s*/, request->{headers}{accept} // '' };
}

sub want_json {
    my $accept = parse_accept;
    # prefer 'text/html over 'application/json' if equal, but default to 'application/json'
    ($accept->{'text/html'} // 0) >= ($accept->{'application/json'} // 1) ? 0 : 1;
}

################
#### NEW API ###
################

sub datetime_to_millisecond_epoch {
    int($_[0]->hires_epoch * 1000);
}

# will throw errors
sub get_nodes {
    my ($filter) = @_;
    $filter //= {};
    my @nodes = $disbatch->nodes->find($filter)->sort({node => 1})->all;
    for my $node (@nodes) {
        $node->{id} = "$node->{_id}";
        $node->{timestamp} = datetime_to_millisecond_epoch($node->{timestamp}) if ref $node->{timestamp} eq 'DateTime';
    }
    \@nodes;
}

get '/nodes' => sub {
    undef $disbatch->{mongo};
    my $nodes = try { get_nodes } catch { status 400; "Could not get current nodes: $_" };
    if ((status() // 200) == 400) {
        Limper::warning $nodes;
        return send_json { error => $nodes }, send_json_options;
    }
    send_json $nodes, send_json_options;
};

get qr'^/nodes/(?<node>.+)' => sub {
    undef $disbatch->{mongo};
    my $filter = try { {_id => MongoDB::OID->new(value => $+{node})} } catch { {node => $+{node}} };
    my $node = try { get_nodes($filter) } catch { status 400; "Could not get node $+{node}: $_" };
    if ((status() // 200) == 400) {
        Limper::warning $node;
        return send_json { error => $node }, send_json_options;
    }
    send_json $node->[0], send_json_options;
};

#  postJSON('/nodes/' + row.rowId , { maxthreads: newValue}, loadQueues);
post qr'^/nodes/(?<node>.+)' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;

    unless (keys %$params) {
        status 400;
        return send_json {error => 'No params'}, send_json_options;
    }
    my @valid_params = qw/maxthreads/;
    for my $param (keys %$params) {
        unless (grep $_ eq $param, @valid_params) {
            status 400;
            return send_json { error => 'Invalid param', param => $param}, send_json_options;
        }
    }
    my $node = $+{node};	# regex on next line clears $+
    if (exists $params->{maxthreads} and defined $params->{maxthreads} and $params->{maxthreads} !~ /^\d+$/) {
        status 400;
        return send_json {error => 'maxthreads must be a non-negative integer or null'}, send_json_options;
    }
    my $filter = try { {_id => MongoDB::OID->new(value => $node)} } catch { {node => $node} };
    my $res = try {
        $disbatch->nodes->update_one($filter, {'$set' => $params});
    } catch {
        Limper::warning "Could not update node $node: $_";
        $_;
    };
    my $reponse = {
        ref $res => {%$res},
    };
    unless ($res->{matched_count} == 1) {
        status 400;
        if ($res->$_isa('MongoDB::UpdateResult')) {
            $reponse->{error} = $reponse->{'MongoDB::UpdateResult'};
        } else {
            $reponse->{error} = "$res";
        }
    }
    send_json $reponse, send_json_options;
};

# This is needed at least to create queues in the web interface.
get '/plugins' => sub {
    send_json $disbatch->{config}{plugins}, send_json_options;
};

get '/queues' => sub {
    undef $disbatch->{mongo};
    my $queues = try { $disbatch->scheduler_report } catch { status 400; "Could not get current queues: $_" };
    if ((status() // 200) == 400) {
        Limper::warning $queues;
        return send_json { error => $queues }, send_json_options;
    }
    send_json $queues, send_json_options;
};

get qr'^/queues/(?<queue>.+)$' => sub {
    undef $disbatch->{mongo};

    my $key = try { MongoDB::OID->new(value => $+{queue}); 'id' } catch { 'name' };
    my $queues = try { $disbatch->scheduler_report } catch { status 400; "Could not get current queues: $_" };
    if ((status() // 200) == 400) {
        Limper::warning $queues;
        return send_json { error => $queues }, send_json_options;
    }
    my ($queue) = grep { $_->{$key} eq $+{queue} } @$queues;
    send_json $queue, send_json_options;
};

sub map_plugins {
    my %plugins = map { $_ => 1 } @{$disbatch->{config}{plugins}};
    \%plugins;
}

post '/queues' => sub {
    undef $disbatch->{mongo};
    my $params = parse_params;
    unless (($params->{name} // '') and ($params->{plugin} // '')) {
        status 400;
        return send_json { error => 'name and plugin required' }, send_json_options;
    }
    my @valid_params = qw/name plugin/;
    for my $param (keys %$params) {
        unless (grep $_ eq $param, @valid_params) {
            status 400;
            return send_json { error => 'Invalid param', param => $param}, send_json_options;
        }
    }
    unless (map_plugins->{$params->{plugin}}) {
        status 400;
        return send_json { error => 'Unknown plugin', plugin => $params->{plugin} }, send_json_options;
    }

    my $res = try { $disbatch->queues->insert_one($params) } catch { Limper::warning "Could not create queue $params->{name}: $_"; $_ };
    my $reponse = {
        ref $res => {%$res},
        id => $res->{inserted_id},
    };
    unless (defined $res->{inserted_id}) {
        status 400;
        $reponse->{error} = "$res";
        $reponse->{ref $res}{result} = { ref $reponse->{ref $res}{result} => {%{$reponse->{ref $res}{result}}} } if ref $reponse->{ref $res}{result};
    }
    send_json $reponse, send_json_options;
};

post qr'^/queues/(?<queue>.+)$' => sub {
    my $queue = $+{queue};
    undef $disbatch->{mongo};
    my $params = parse_params;
    my @valid_params = qw/threads name plugin/;

    unless (keys %$params) {
        status 400;
        return send_json {error => 'no params'}, send_json_options;
    }
    for my $param (keys %$params) {
        unless (grep $_ eq $param, @valid_params) {
            status 400;
            return send_json { error => 'unknown param', param => $param}, send_json_options;
        }
    }
    if (exists $params->{plugin} and !map_plugins()->{$params->{plugin}}) {
        status 400;
        return send_json { error => 'unknown plugin', plugin => $params->{plugin} }, send_json_options;
    }
    if (exists $params->{threads} and $params->{threads} !~ /^\d+$/) {
        status 400;
        return send_json {error => 'threads must be a non-negative integer'}, send_json_options;
    }
    if (exists $params->{name} and (ref $params->{name} or !($params->{name} // ''))){
        status 400;
        return send_json {error => 'name must be a string'}, send_json_options;
    }

    my $filter = try { {_id => MongoDB::OID->new(value => $queue)} } catch { {name => $queue} };
    my $res = try {
        $disbatch->queues->update_one($filter, {'$set' => $params});
    } catch {
        Limper::warning "Could not update queue $queue: $_";
        $_;
    };
    my $reponse = {
        ref $res => {%$res},
    };
    unless ($res->{matched_count} == 1) {
        status 400;
        $reponse->{error} = "$res";
    }
    send_json $reponse, send_json_options;
};

del qr'^/queues/(?<queue>.+)$' => sub {
    undef $disbatch->{mongo};

    my $filter = try { {_id => MongoDB::OID->new(value => $+{queue})} } catch { {name => $+{queue}} };
    my $res = try { $disbatch->queues->delete_one($filter) } catch { Limper::warning "Could not delete queue '$+{queue}': $_"; $_ };
    my $reponse = {
        ref $res => {%$res},
    };
    unless ($res->{deleted_count}) {
        status 400;
        $reponse->{error} = "$res";
    }
    send_json $reponse, send_json_options;
};

# returns an MongoDB::OID object of either a simple string representation of the OID or a queue name, or undef if queue not found/valid
sub get_queue_oid {
    my ($queue) = @_;
    my $queue_id = try {
        $disbatch->queues->find_one({_id => MongoDB::OID->new(value => $queue)});
    } catch {
        try { $disbatch->queues->find_one({name => $queue}) } catch { Limper::warning "Could not find queue $queue: $_"; undef };
    };
    defined $queue_id ? $queue_id->{_id} : undef;
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

sub post_tasks {
    my ($legacy_params) = @_;
    undef $disbatch->{mongo};
    my $params = parse_params;
    # NEW:
    # { "queue": queue, "params": single_task_params }
    # { "queue": queue, "params": [single_task_params, another_task_params, ...] }
    # { "queue": queue, "params": generic_task_params, "collection": collection, "filter": collection_filter }

    $params = { params => $params } if ref $params eq 'ARRAY';
    $params = { %$params, %$legacy_params } if defined $legacy_params;

    my $queue_id = get_queue_oid($params->{queue});
    unless (defined $queue_id) {
        status 400;
        return send_json { error => 'queue not found' }, send_json_options;
    }

    my $task_params = $params->{params};
    my $keys = join(',', sort keys %$params);
    # { "queue": queue, "params": single_task_params }
    # NOTE: wait does anything use this??
    if ($keys eq 'params,queue' and ref $task_params eq 'HASH') {
        $task_params = [$task_params];
    }
    # { "queue": queue, "params": [single_task_params, another_task_params, ...] }
    if ($keys eq 'params,queue' and ref $task_params eq 'ARRAY') {
        # validate array of hash params
        if (!@$task_params or grep { ref $_ ne 'HASH' } @$task_params) {
            status 400;
            return send_json { error => "'params' must be a JSON array of task params objects" }, send_json_options;
        } elsif (grep { keys %$_ == 0 } @$task_params) {
            status 400;
            return send_json { error => "'params' must be a JSON array of task params objects with key/value pairs" }, send_json_options;
        }
        # $task_params is ready
    # { "queue": queue, "params": generic_task_params, "collection": collection, "filter": collection_filter }
    } elsif ($keys eq 'collection,filter,params,queue' and ref $task_params eq 'HASH') {
        # validate and parse
        # {"migration":"foo"}
        # {"migration":"document.migration","user1":"document.username"}
        if (ref $params->{filter} ne 'HASH') {
            status 400;
            return send_json { error => "'filter' must be a JSON object" }, send_json_options;
        } elsif (!ref $params->{collection} eq '' or !$params->{collection}) {
            status 400;
            return send_json { error => "'collection' required and must be a scalar (string)'" }, send_json_options;
        }

        my @fields = grep /^document\./, values %$task_params;
        my %fields = map { s/^document\.//; $_ => 1 } @fields;

        my $cursor = $disbatch->mongo->coll($params->{collection})->find($params->{filter})->fields(\%fields);
        # FIXME: maybe fail unless $cursor->has_next
        my @tasks;
        my $error;
        try {
            # NOTE: yes, this loads all of them into @tasks
            while (my $doc = $cursor->next) {
                my $task = clone $task_params;
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
            Limper::warning "Could not iterate on collection $params->{collection}: $_";
            $error = "$_";
        };
        if (defined $error) {
            status 400;
            return send_json { error => $error }, send_json_options;
        }
        $task_params = \@tasks;
        # $task_params is ready
    } else {
        # fail
        status 400;
        return send_json { error => 'invalid parameters passed' }, send_json_options;
    }

    my $res = create_tasks($queue_id, $task_params);	# doing 100k at once only take 12 seconds on my 13" rMBP

    my $reponse = {
        ref $res => {%$res},
    };
    unless (@{$res->{inserted}}) {
        status 400;
        $reponse->{error} = 'Unknown error';
    }
    send_json $reponse, send_json_options;
};

post '/tasks' => sub {
    post_tasks();
};

=item GET /tasks

Parameters: FIXME (was: valid options according to the tasks->query schema.)

Returns FIXME (was: valid fields to search for tasks if invalid or no parameters), or the results of the search, in JSON.

FIXME: in query.tt at least toggleGroup() should run at $(document).ready() when returning a form because of invalid params, instead of only showing the limit (bug is there, not at all here)

=cut

# NOTE: handles .terse, .full, and .epoch for GET /tasks
# * 'ctime' and 'mtime' are like 2019-01-23T19:42:56, unless .epoch, which will make them hires epoch times (float)
# * 'stdout' and 'stderr' are actual content, unless .terse for "[terse mode]" or .full to replace with gfs docs
# * the following are equivalent:
#   $ curl 'http://localhost:3002/tasks?.pretty=1&status=1&.terse=1&.epoch=1'
#   $ curl -XGET -H'Content-Type: application/json' -d'{"status":1,".pretty":1,".terse":1,".epoch":1}' http://localhost:8080/tasks
# * and get you a result like default POST /tasks/search:
#   $ curl -XPOST -H'Content-Type: application/json' -d '{"filter":{"status":1},"pretty":1}' http://localhost:8080/tasks/search
# NOTE: i hate this, but it should maybe be here for backcompat
sub _munge_tasks {
    my ($tasks, $options) = @_;
    $tasks = [$tasks] if ref $tasks eq 'HASH';	# NOTE: if $options->{'.limit'} is 1
    for my $task (@$tasks) {
        for my $type (qw/stdout stderr/) {
            if ($options->{'.terse'}) {
                $task->{$type} = '[terse mode]' if defined $task->{$type} and !$task->{$type}->$_isa('MongoDB::OID') and $task->{$type};
            } elsif ($options->{'.full'} // 0 and $task->{$type}->$_isa('MongoDB::OID')) {
                $task->{$type} = try { $disbatch->get_gfs($task->{$type}) } catch { Limper::warning "Could not get task $task->{_id} $type: $_"; $task->{$type} };
            }
        }
        if ($options->{'.epoch'}) {
            for my $type (qw/ctime mtime/) {
                $task->{$type} = $task->{$type}->hires_epoch if ref $task->{$type} eq 'DateTime';
            }
        }
    }
}

get '/tasks' => sub {
    undef $disbatch->{mongo};	# FIXME: why is this added?
    my ($params, $options) = parse_params;	# NOTE: $options may contain: .limit .skip .count .pretty .terse .epoch .full
    $params = undef if defined $params and $params eq '';	# FIXME: maybe move to parse_params() above
    my $want_json = want_json;

    my $indexes = $util->get_indexes($disbatch->tasks);
    my $schema = {
            verb => 'GET',
            limit => 100,
            title => 'Disbatch Tasks Query',
            subtitle => 'Warning: this can return a LOT of data!',
            params => +{ map { map { $_ => { repeatable => 'yes', type => ['string' ]} } @$_ } @$indexes },
    };
    if (!$want_json and !%$params and !%$options) {
        my $result = { schema => $schema, indexes => $indexes };
        return template 'query.tt', $result;
    }

    my $result = $util->query($params, $options, $schema->{title}, $oid_keys, $disbatch->tasks, request->{path}, $want_json, $indexes);
    if ($want_json) {
        status 400 if ref $result ne 'ARRAY' and exists $result->{error};
        _munge_tasks($result, $options);
        send_json $result, send_json_options, pretty => $options->{'.pretty'} // 0;
    } else {
        if (exists $result->{error}) {
            $result->{schema} = $schema;
            $result->{schema}{error} = $result->{error};
            status 400;
        }
        _munge_tasks($result, $options);	# FIXME: do we want _munge_tasks() here too? well let's TIAS
        template 'query.tt', $result;
    }
};


=item GET /tasks/:id

Parameters: Task OID in URL

Returns the task matching OID as JSON, or C<{ "error": "no task with id :id" }> and status C<404> if OID not found.
Or, via a web browser (based on C<Accept> header value), returns the task matching OID with some formatting, or C<No tasks found matching query> if OID not found.

=cut

get qr'^/tasks/(?<id>[0-9a-f]{24})$' => sub {
    my $title = "Disbatch Single Task Query";
    my $want_json = want_json;
    my $result = $util->query({id => $+{id}}, {'.limit' => 1}, $title, $oid_keys, $disbatch->tasks, request->{path}, $want_json, [['id']]);
    if ($want_json) {
        if (!keys %$result) {
            status 404;
            $result = { error => "no task with id $+{id}" };
        } elsif (exists $result->{error}) {
            status 400;
        }
        send_json $result, send_json_options, pretty => 1;
    } else {
        if (!defined $result->{result}) {
            status 404;
        } elsif (exists $result->{error}) {
            status 400;
        }
        template 'query.tt', $result;
    }
};

sub get_balance {
    my $balance = $disbatch->balance->find_one() // { notice => 'balance document not found' };
    delete $balance->{_id};
    $balance->{known_queues} = [ $disbatch->queues->distinct("name")->all ];
    $balance->{settings} = $disbatch->{config}{balance};	# { log => 1, verbose => 0, pretend => 0, enabled => 0 }
    $balance;
}

sub post_balance {
    my $params = parse_params;

    # TODO: make this not all hardcoded:
    my $error = try {
        die join(',', sort keys %$params) unless join(',', sort keys %$params) =~ /^(?:disabled,)?max_tasks,queues$/;

        if (defined $params->{disabled}) {
            die unless $params->{disabled} =~ /^\d+$/;
            die if $params->{disabled} and $params->{disabled} < time;
        }

        die unless ref $params->{queues} eq 'ARRAY';
        ref $_ eq 'ARRAY' or die for @{$params->{queues}};
        my @q;
        my @known_queues = $disbatch->queues->distinct("name")->all;
        for my $q (@{$params->{queues}}) {
            ref $_ and die ref $_ for @$q;
            /^[\w-]+$/ or die for @$q;
            for my $e (@$q) {
                grep { /^$e$/ } @known_queues or die;
            }
            push @q, @$q;
        }
        my %q = map { $_ => undef } @q;
        die unless @q == keys %q;
        die unless join(',', sort @q) eq join(',', sort keys %q);

        die unless ref $params->{max_tasks} eq 'HASH';
        /^\d+$/ or die for values %{$params->{max_tasks}};
        /^[*0-6] (?:[01]\d|2[0-3]):[0-5]\d$/ or die for keys %{$params->{max_tasks}};
        return undef;
    } catch {
        status 400;
        return { status => 'failed: invalid json passed ' . $_ };
    };
    return $error if defined $error;

    $_ += 0 for values %{$params->{max_tasks}};

    $disbatch->balance->update_one({}, {'$set' => $params }, {upsert => 1});
    { status => 'success: queuebalance modified' };
};

get '/balance' => sub {
    my $want_json = want_json;
    if ($want_json) {
        send_json get_balance(), send_json_options, pretty => 1;
    } else {
        template 'balance.tt', get_balance();
    }
};

post '/balance' => sub {
    send_json post_balance(), send_json_options;
};

# For Disbatch basic status.
# Returns hash with keys status and message.
# NOTE: this *is* disbatch (web). but we now check if any nodes are running, instead of if the web server is running on a list of hosts (as old disbatch was monolithic)
sub check_disbatch {
    try {
        # $nodes is an ARRAY of nodes, each HASH has a 'timestamp' field (in ms) so you can tell if it's running, as well as 'node' and 'id'
        my $nodes = get_nodes;
        if (!@$nodes) {
            return { status => 'WARNING', message => 'No Disbatch nodes found' };
        }
        my $status = {};
        my $now = time;
        for my $node (@$nodes) {
            my $timestamp = int($node->{timestamp} / 1000);
            if ($timestamp + 60 < $now) {
                # old
                $status->{stale}{$node->{node}} = $now - $timestamp;
            } else {
                $status->{fresh}{$node->{node}} = $now - $timestamp;
            }
        }
        if (keys %{$status->{fresh}}) {
            return { status => 'OK', message => 'Disbatch is running on one or more nodes', nodes => $status };
        } else {
            return { status => 'CRITICAL', message => 'No active Disbatch nodes found', nodes => $status };
        }
    } catch {
        return { status => 'CRITICAL', message => "Could not get current Disbatch nodes: $_" };
    };
}

sub check_queuebalance {
    my ($time_diff) = @_;
    return { status => 'OK', message => 'queuebalance disabled' } unless $disbatch->{config}{balance}{enabled};
    # FIXME: return some sort of OK status if 'balance' collection doesn't exist (no QueueBalance) or $qb below is undef
    my $qb = $disbatch->balance->find_one({}, {status => 1, message => 1, timestamp => 1, _id => 0});
    return $qb if $qb->{status} eq 'CRITICAL' and !exists $qb->{timestamp}; # error via _mongo()	# FIXME: this will never happen because rewrite (wait why??), but maybe should check for timestamp anyway
    my $timestamp = delete $qb->{timestamp};
    return { status => 'CRITICAL' , message => 'queuebalanced not running for ' . (time - $timestamp) . 's' } if $timestamp < time - $time_diff;
    return $qb if $qb->{status} =~ /^(?:OK|WARNING|CRITICAL)$/;
    return { status => 'CRITICAL', message => 'queuebalanced unknown status', result => $qb };
}

sub checks {
    my $checks = {};
    if ($disbatch->{config}{monitoring}) {
        $checks->{disbatch} = check_disbatch();
        $checks->{queuebalance} = check_queuebalance(60);	# FIXME: don't hardcode $time_diff (60) for queuebalance status?
    } else {
        $checks->{disbatch} = { status => 'OK', message => 'monitoring disabled' };
        $checks->{queuebalance} = { status => 'OK', message => 'monitoring disabled' };
    }
    $checks;
}

get '/monitoring' => sub {
    send_json checks(), send_json_options;
};

1;

__END__

=encoding utf8

=head1 NAME

Disbatch::Web - Disbatch Command Interface (JSON REST API and web browser interface to Disbatch).

=head1 EXPORTED

parse_params, send_json_options, template

=head1 SUBROUTINES

=over 2

=item init(config_file => $config_file)

Parameters: path to the Disbatch config file. Default is C</etc/disbatch/config.json>.

Initializes the settings for the web server.

Returns nothing.

=item template($template, $params)

Parameters: template (C<.tt>) file name in the C<views/> directory, C<HASH> of parameters for the template.

Creates a web page based on the passed data.

Sets C<Content-Type> to C<text/html>.

Returns the generated html document.

NOTE: this sub is automatically exported, so any package using L<Disbatch::Web> can call it.

=item parse_params

Parameters: none

Parses request parameters in the following order:

* from the request body if the Content-Type is C<application/x-www-form-urlencoded>

* from the request body if the Content-Type is C<application/json>

* from the request query otherwise

It then puts any fields starting with C<.> into their own C<HASH> C<$options>.

Returns the C<HASH> of the parsed request parameters, and if C<wantarray> also returns the C<HASH> of options.

NOTE: this sub is automatically exported, so any package using L<Disbatch::Web> can call it.

=item send_json_options

Parameters: none

Used to enable the following options when returning JSON: C<allow_blessed>, C<canonical>, and C<convert_blessed>.

Returns a C<list> of key/value pairs of options to pass to C<send_json>.

NOTE: this sub is automatically exported, so any package using L<Disbatch::Web> can call it.

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

=item get_balance

Parameters: none

Returns a C<HASH> of the balance doc without the C<_id> field, with the following added:
field C<known_queues> with value an C<ARRAY> of all existing queue names, field C<settings> with value the C<HASH> of C<config.balance>.
If the balance doc does not exist, the field C<notice> with value C<balance document not found> is added.

=item post_balance

Parameters: none (but parses request parameters, see C<POST /balance> below)

Sets the C<balance> document fields given in the request parameters to the given values.

Returns C<< { status => 'success: queuebalance modified' } >> on success, or C<< { status => 'failed: invalid json passed ' . $_ } >> with HTTP status of C<400> on error.

=back

=head1 JSON ROUTES

NOTE: all JSON routes use C<send_json_options>, documented above.

=over 2

=item GET /nodes

Parameters: none.

Returns an Array of node Objects defined (with C<id> the stringified C<_id>) on success, C<< { "error": "Could not get current nodes: $_" } >> on error.

Sets HTTP status to C<400> on error.

Note: new in Disbatch 4

=item GET /nodes/:node

URL: C<:node> is the C<_id> if it matches C</\A[0-9a-f]{24}\z/>, or C<node> name if it does not.

Parameters: none.

Returns node Object (with C<id> the stringified C<_id>) on success, C<< { "error": "Could not get node $node: $_" } >> on error.

Sets HTTP status to C<400> on error.

Note: new in Disbatch 4

=item POST /nodes/:node

URL: C<:node> is the C<_id> if it matches C</\A[0-9a-f]{24}\z/>, or C<node> name if it does not.

Parameters: C<< { "maxthreads": maxthreads } >>

"maxthreads" is a non-negative integer or null

Returns C<< { ref $res: Object } >> or C<< { ref $res: Object, "error": error_string_or_reponse_object } >>

Sets HTTP status to C<400> on error.

Note: new in Disbatch 4

=item GET /plugins

Parameters: none.

Returns an Array of allowed plugin names.

Should never fail.

Note: replaces /queue-prototypes-json

=item GET /queues

Parameters: none.

Returns an Array of queue Objects on success, C<< { "error": "Could not get current queues: $_" } >> on error.

Each item has the following keys: id, plugin, name, threads, queued, running, completed

Sets HTTP status to C<400> on error.

Note: replaces /scheduler-json

=item GET /queues/:queue

URL: C<:queue> is the C<_id> if it matches C</\A[0-9a-f]{24}\z/>, or C<name> if it does not.

Parameters: none.

Returns a queue Object on success, C<< { "error": "Could not get current queues: $_" } >> on error.

Each item has the following keys: id, plugin, name, threads, queued, running, completed

Sets HTTP status to C<400> on error.

=item POST /queues

Create a new queue.

Parameters: C<< { "name": name, "plugin": plugin } >>

C<name> is the desired name for the queue (must be unique), C<plugin> is the plugin name for the queue.

Returns: C<< { ref $res: Object, "id": $inserted_id } >> on success; C<< { "error": "name and plugin required" } >>,
C<< { "error": "Invalid param", "param": $param } >>, or C<< { "error": "Unknown plugin", "plugin": $plugin } >> on input error; or
C<< { ref $res: Object, "id": null, "error": "$res" } >> on MongoDB error.

Sets HTTP status to C<400> on error.

Note: replaces /start-queue-json

=item POST /queues/:queue

URL: C<:queue> is the C<_id> if it matches C</\A[0-9a-f]{24}\z/>, or C<name> if it does not.

Parameters: C<< { "name": name, "plugin": plugin, "threads": threads } >>

C<name> is the new name for the queue (must be unique), C<plugin> is the new plugin name for the queue (must be defined in the config file), 
C<threads> must be a non-negative integer. Only one of C<name>, C<plugin>, and  C<threads> is required, but any combination is allowed.

Returns C<< { ref $res: Object } >> or C<< { "error": error } >>

Sets HTTP status to C<400> on error.

Note: replaces /set-queue-attr-json

=item DELETE /queues/:queue

Deletes the specified queue.

URL: C<:queue> is the C<_id> if it matches C</\A[0-9a-f]{24}\z/>, or C<name> if it does not.

Parameters: none

Returns: C<< { ref $res: Object } >> on success, or C<< { ref $res: Object, "error": "$res" } >> on error.

Sets HTTP status to C<400> on error.

Note: replaces /delete-queue-json

=item GET /tasks

WARNING: everything in this section is for the old  C<POST /tasks/search>!

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

Note: replaces C<POST /tasks/search>

=item POST /tasks?queue=:queue[&collection=:collection]

URL: C<:queue> is the C<_id> if it matches C</\A[0-9a-f]{24}\z/>, or C<name> if it does not. C<:collection> is a MongoDB collection name.

Parameters: an array of task params objects if not passing a C<collection> in the URL, or C<< { "filter": filter, "params": params } >>

C<filter> is a filter expression (query) object for the C<:collection> collection.

C<params> is an object of task params. To insert a document value from a query into the params, prefix the desired key name with C<document.> as a value.

Returns: C<< { ref $res: Object } >> on success; C<< { "error": "params must be a JSON array of task params" } >>, C<< { "error": "filter and params required and must be name/value objects" } >>
or C<< { "error": "queue not found" } >> on input error; C<< { "error": "Could not iterate on collection $collection: $error" } >> on query error, or C<< { ref $res: Object, "error": "Unknown error" } >> on MongoDB error.

Sets HTTP status to C<400> on error.

Note: new in 4.2, replaces C<POST /tasks/:queue> and C<POST /tasks/:queue/:collection>

=item GET /balance

Parameters: none

Returns a web page to view and update Queue Balance settings if the C<Accept> header wants C<text/html>, otherwise returns a pretty JSON result of C<get_balance>

=item POST /balance

Parameters: C<{ "max_tasks": max_tasks, "queues": queues, "disabled": disabled }>

C<max_tasks> is a C<HASH> where keys match C</^[*0-6] (?:[01]\d|2[0-3]):[0-5]\d$/> (that is, C<0..6> or C<*> for DOW, followed by a space and a 24-hour time) and values are non-negative integers.

C<queues> is an C<ARRAY> of C<ARRAY>s of queue names which must exist

C<disabled> is a timestamp which must be in the future (optional)

Sets the C<balance> document fields given in the above parameters to the given values.

Returns JSON C<{"status":"success: queuebalance modified"}> on success, or C<{"status":"failed: invalid json passed " . $_}> with HTTP status of C<400> on error.

=item GET /monitoring

Params: none

Returns C<{"disbatch":{"status":status,"message":message},"queuebalance":{"status":qb_status,"message":qb_message}}>, where C<status> and C<qb_status> will be C<OK> or C<CRITICAL>

If C<config.monitoring> is false, status will be C<OK> and message will be C<monitoring disabled> for both.
If C<config.balance.enabled> is false, status will be C<OK> and message will be C<queuebalance disabled> for C<queuebalance>.

=back

=head1 CUSTOM ROUTES

You can set an array of package names to C<web_extensions> in the config file to load any custom routes. They are parsed in order after the above routes.
Note that if a request which matches your custom route is also matched by an above route, your custom route will never be called.
See L<Disbatch::Web::Files> for an example (that package is automatically loaded at the end, after any custom routes).

=head1 BROWSER ROUTES

Note: this are loaded from L<Disbatch::Web::Files>.

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

This software is Copyright (c) 2016, 2019 by Ashley Willis.

This is free software, licensed under:

  The Apache License, Version 2.0, January 2004
