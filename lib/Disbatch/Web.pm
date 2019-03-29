package Disbatch::Web;

use 5.12.0;
use strict;
use warnings;

use Cpanel::JSON::XS;
use Data::Dumper;
use Disbatch;
use Exporter qw/ import /;
use File::Slurp;
use Limper::SendFile;
use Limper::SendJSON;
use Limper;
use Log::Log4perl;
use MongoDB::OID 1.0.4;
use Safe::Isa;
use Template;
use Time::Moment;
use Try::Tiny::Retry;
use URL::Encode qw/url_params_mixed/;

our @EXPORT = qw/ parse_params send_json_options template /;

sub send_json_options { allow_blessed => 1, canonical => 1, convert_blessed => 1, pretty => 0 }		# from remotecontrol/config.yml

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

This software is Copyright (c) 2016 by Ashley Willis.

This is free software, licensed under:

  The Apache License, Version 2.0, January 2004
