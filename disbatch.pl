#!/usr/bin/perl -W

##
## synmig - this is a very simple CLI which is a pretty thin wrapper around
## the JSON interface provided by migrated.
##
## Nothing here should require too much explanation, and documentation to
## use this tool is provided if you perldoc this file.
##

=head1 NAME

synmig - Synacor Migration Framework - Client CLI Tool

=head1 DESCRIPTION

This tool interfaces with the migrated process via the JSON API.  It   
allows you create new queues, spin off new tasks, manage users, and
alter the parameters of the migration engine while in operation.

=head1 USAGE

    migrate.pl [<options>] [<command>...]

=head2 OPTIONS

    -u <URL>            migrated JSON API URL
    -n <username>       API username
    -p <password>       API password
    -h		   Display this message
    
=head2 COMMANDS

    reloadqueues

    status

    queue types
    queue set <queue> <key> <value>
    queue start <type> <name>
    queue task <queue> {[value], ...}
    queue tasks <queue> <group> <filter> [<col1>, ...]

    enclosure <queue> <group> <filter> [<col1>, ...]


    user groups
    user list <group> [<filter>]
    user add <group> <user> <password> [<key> <value>, ...]
    user get <group> <username>
    user set <group> <username> [<key> <value>, ...]

=head1 EXAMPLES

=head2 STATUS

The first example is to grab the current running status of the migrated
process.  This will list all queues, and the state they are in:

  mbusigin@tesla:~/synacor-migration-framework$ ./synmig.pl status
  .------------+-----------+--------+------------+--------+------------.
  | Queue #    | Threads   | To-Do  | Preemptive | Done   | Processing |
  +------------+-----------+--------+------------+--------+------------+
  | 2158219    | 3         | 26013  | 1          | 1427   | 3          |
  '------------+-----------+--------+------------+--------+------------'

=head2 TWEAKING QUEUE SETTINGS

Since there are more than 26,000 tasks, 3 threads seems a bit spartan.  We
can increase that by increasing the maxthread queue attribute:

  mbusigin@tesla:~/synacor-migration-framework$ ./synmig.pl queue set 2158219 maxthreads 10

=head2 STARTING A NEW QUEUE

Next, let's create a new queue:

  mbusigin@tesla:~/synacor-migration-framework$ ./synmig.pl queue start Synacor::Disbatch::Queue::IMAP2IMAP foo
  New Queue #2185663


=cut            

use strict;
use Data::Dumper;
use LWP::UserAgent;
use JSON;
use Text::Table;
use Text::CSV_XS;
use IO::Wrap;


my $json = JSON->new;


my $USAGE =
qq/
Synacor Migration Framework - Client CLI Tool

DESCRPTION

    This tool interfaces with the migrated process via the JSON API.  It
    allows you create new queues, spin off new task, manage users, and
    alter the parameters of the migration engine while in operation.

USAGE

    migrate.pl [<options>] [<command>...]

       OPTIONS
               -u <URL>            migrated JSON API URL
               -n <username>       API username
               -p <password>       API password
               -h		   Display this message
    
      COMMANDS
               reloadqueues
               
               status

               queue types
               queue set <queue> <key> <value>
               queue start <type> <name>
               queue task <queue> {[value], ...}
               queue tasks <queue> <group> <filter> [<col1>, ...]
               queue search <queue> <filter>

               enclosure <queue> <group> <filter> [<col1>, ...]

               user groups
               user list <group> [<filter>]
               user add <group> <user> <password> [<key> <value>, ...]
               user get <group> <username>
               user set <group> <username> [<key> <value>, ...]

/;


my %options = 
(
    '-u'		=> ['url', 1],
    '-n'		=> ['username', 1],
    '-p'		=> ['password', 1],

    '-h'		=> ['help', 0],
    '--help'		=> ['help', 0],
);

my %commands =
(
    'status'		=> \&parse_status,
    'queue'		=> \&parse_queue,
    'user'		=> \&parse_user,
    'reloadqueues'	=> \&parse_reloadqueues,
    'enclosure'		=> \&parse_enclosure,
);


sub api_url
{
    my $params = shift;
    my $url = $params->{ 'url' } ||= 'http://localhost:8080';
    
    return $url;
}


sub parse_reloadqueues
{
    my $params = shift;
    my @ARGS = shift;
    $params->{ 'execute' } = \&reloadqueues;
    return( (1, 'Reload Queues') );
}


sub parse_status
{
    my $params = shift;
    my @ARGS = shift;
    
    $params->{ 'execute' } = \&status;
    return( (1, 'Status') );
}


sub parse_enclosure
{
    my $params = shift;
    my (@ARGS) = @_;

    my $perl = '';
    while( <STDIN> )
    {
        $perl .= $_;
    }

    
    $params->{ 'execute' } = \&queue_tasks;
    $params->{ 'queueid' } = shift @ARGS;
    $params->{ 'group' } = shift @ARGS;
    $params->{ 'filter' } = shift @ARGS;
    unshift @ARGS, $perl;
    
    $params->{ 'columns' } = $json->encode( \@ARGS );
    
    return( (1, undef) );
}


sub parse_queue
{
    my $params = shift;
    my (@ARGS) = @_;

    my %queue_commands =
    (
        'set'		=> \&parse_queue_set,
        'start'		=> \&parse_queue_start,
        'task'		=> \&parse_queue_task,
        'tasks'		=> \&parse_queue_tasks,
        'search'	=> \&parse_queue_search,
        'types'		=> \&parse_queue_types,
    );

    return( (0, "Command '$params->{command}' needs a sub-command.  Options: " . join(' ', keys %queue_commands)) ) if scalar(@ARGS) < 1 or !defined($ARGS[0]);

    my $command = shift @ARGS;
    return( (0, "Queue sub-command '$command' does not exist.") ) if !exists($queue_commands{$command});

    my $func = $queue_commands{ $command };
    return &$func( $params, @ARGS );
}


sub parse_queue_types
{
    my ( $params, @ARGS ) = @_;
    $params->{ 'execute' } = \&queue_types;
    return( (1, undef) );
}


sub parse_queue_start
{
    my ( $params, @ARGS ) = @_;
    return( (0, "Start takes 2 arguments:  type & name.") ) if scalar(@ARGS) != 2;
    $params->{ 'execute' } = \&queue_start;
    ( $params->{'type'}, $params->{'name'} ) = @ARGS;
    return( (1, undef) );
}


sub parse_queue_search
{
    my ( $params, @ARGS ) = @_;
    return( (0, "Search takes 2 arguments:  queue & filter.") ) if scalar(@ARGS) != 2;
    $params->{ 'execute' } = \&queue_search;
    ( $params->{'queue'}, $params->{'filter'} ) = @ARGS;
    return( (1, undef) );
}


sub parse_queue_set
{
    my ( $params, @ARGS ) = @_;
    return( (0, "Set takes 3 arguments:  queueid, key & value.") ) if scalar(@ARGS) != 3;
    $params->{ 'execute' } = \&queue_set;
    ( $params->{'queueid'}, $params->{'key'}, $params->{'value'} ) = @ARGS;
    return( (1, undef) );
}


sub parse_queue_task
{
    my ( $params, @ARGS ) = @_;
    return( (0, "Item takes at least one argument:  queueid.\n") ) if scalar(@ARGS) < 1;
    $params->{ 'execute' } = \&queue_task;
    $params->{ 'queueid' } = shift @ARGS;
    $params->{ 'object' } = $json->encode( [\@ARGS] );
    return( (1, undef) );
}


sub parse_queue_tasks
{
    my ( $params, @ARGS) = @_;
    return( (0, "Item takes at least 3 arguments: queueid, group, filter") ) if scalar(@ARGS) < 3;
    $params->{ 'execute' } = \&queue_tasks;
    $params->{ 'queueid' } = shift @ARGS;
    $params->{ 'group' } = shift @ARGS;
    $params->{ 'filter' } = shift @ARGS;
    $params->{ 'columns' } = $json->encode( \@ARGS );
    return( (1, undef) );
}


sub parse_user
{
    my $params = shift;
    my (@ARGS) = @_;

    my %queue_commands =
    (
        'groups'	=> \&parse_user_groups,
        'list'		=> \&parse_user_list,
        'add'		=> \&parse_user_add,
        'get'		=> \&parse_user_get,
        'set'		=> \&parse_user_set,
    );

    return( (0, "Command '$params->{command}' needs a sub-command.  Options: " . join(' ', keys %queue_commands)) ) if scalar(@ARGS) < 1 or !defined($ARGS[0]);

    my $command = shift @ARGS;
    return( (0, "Queue sub-command '$command' does not exist.") ) if !exists($queue_commands{$command});

    my $func = $queue_commands{ $command };
    return &$func( $params, @ARGS );
}


sub parse_user_set
{
    my $params = shift;
    my (@ARGS) = @_;
    
    return( (0, 'Need at least group, username, and one key/value pair') ) if scalar(@ARGS) < 4;
    return( (0, 'Must be an even number of arguments:  after group & username, alternating key & value arguments are expected ') ) if scalar(@ARGS) % 2 != 0;
    
    $params->{ 'group' } = shift @ARGS;
    $params->{ 'username' } = shift @ARGS;

    my %user;
    while( (my $key = shift @ARGS) )
    {
        my $value = shift @ARGS;
        $user{ $key } = $value;
    }
    $params->{ 'user' } = \%user;
    $params->{ 'execute' } = \&user_set;
}


sub parse_user_add
{
    my $params = shift;
    my (@ARGS) = @_;
    
    return( (0, 'At least one argument is required:  group') ) if scalar(@ARGS) == 0;
    return( (0, 'Either call this with one argument (group) and supply user data via stdin in CSV form, or supply:  group, username, password & alternating key/value pairs') ) if scalar(@ARGS) > 1 and scalar(@ARGS) < 3;
    return( (0, 'Must be an odd number of arguments:  after group, username & password, alternating key & value arguments are expected') ) if scalar(@ARGS) % 2 == 0;
    
    $params->{ 'execute' } = \&user_add;
    $params->{ 'group' } = shift @ARGS;
    
    # We're taking it in
    if ( scalar(@ARGS) == 0 )
    {
      my $buf = '';
      while( <STDIN> ) { $buf .= $_; }
      $params->{ 'users_csv' } = $buf;
      $params->{ 'users' } = {};
=head1 commented out
      my $csv = Text::CSV_XS->new({ sep_char => ",", eol => $/, binary => 1 }); 
      $csv->column_names( $csv->getline(*STDIN) );
      my @users;
      while( my $row = $csv->getline_hr(*STDIN) )
      {
          push @users, $row;
#          warn Dumper( $row );
      }
      
      $params->{ 'users' } = \@users;
      warn "Users: " . scalar(@users) . "\n";
=cut
    }
    else
    {
        my %user;
        $user{ 'username' } = shift @ARGS;
        $user{ 'password' } = shift @ARGS;
        while( (my $key = shift @ARGS) )
        {
            my $value = shift @ARGS;
            $user{ $key } = $value;
        }
        $params->{ 'users' } = [ \%user ];
    }
}


sub parse_user_groups
{
    my ( $params, @ARGS ) = @_;
    $params->{ 'execute' } = \&user_groups;
    return( (1, undef) );
}


sub parse_user_list
{
    my ( $params, @ARGS ) = @_;
    return( (0, 'List requires at least one argument:  group') ) if scalar(@ARGS) < 1;
    $params->{ 'execute' } = \&user_list;
    $params->{ 'group' } = shift @ARGS;
    $params->{ 'filter' } = shift @ARGS if scalar(@ARGS) > 0;
    return( (1, undef) );
}


sub parse_arguments
{
    my @ARGS = @ARGV;
    my %parameters;
    my $argsleft = scalar( @ARGS );

    ## 
    ## No arguments?  Let caller know by returning -1.
    ##
    if ( scalar(@ARGS) == 0 )
    {
        return( (-1, \%parameters) );
    }
    
    ##
    ## First:  parse options
    ##
    while( scalar(@ARGS) > 0 and $ARGS[0] =~ /^-/ )
    {
        my $opt = shift @ARGS;
        if ( !exists($options{$opt}) )
        {
            print "No such option '$opt'\n";
            return( (0, \%parameters) );
        }
        
        my $optname = $options{ $opt }->[ 0 ];
        $argsleft = scalar( @ARGS );
        my $argsreq = $options{ $opt }->[ 1 ];
        if ( $argsreq > $argsleft )
        {
            print "Option '$opt' ($optname) requires $argsreq argument(s).\n";
            return( (0, \%parameters) );
        }
        
        if ( $argsreq == 1 )
        {
            $parameters{ $optname } = shift @ARGS;
        }
        elsif ( $argsreq == 0 )
        {
            $parameters{ $optname } = 1;
        }
        else
        {
            my @p;
            for ( my $i = 0; $i < $argsreq; $i ++ )
            {
                push @p, pop @ARGS;
            }
            $parameters{ $optname } = \@p;
            
        }
    }

    ##
    ## Second:  parse commands
    ##
    $argsleft = scalar( @ARGS );
    if ( $argsleft < 1 )
    {
        print "No command supplied.\n";
        return( (0, \%parameters) );
    }

    $parameters{ 'command' } = shift @ARGS;
    if ( !exists($commands{$parameters{'command'}}) )
    {
        print "No such command '$parameters{command}'.\n";
        return( (0, \%parameters) );
    }

    if ( my $func = $commands{$parameters{'command'}} )
    {
        my ( $ret, $msg ) = &$func( \%parameters, @ARGS );
        if ( $ret == 0 )
        {
            print $msg . "\n";
            return( (0, \%parameters) );
        }
    }
    
    return( (1, \%parameters) );
}


sub status
{
    my $params = shift;
    my $ua = LWP::UserAgent->new;
    my $url = api_url( $params ) . '/scheduler-json';
    
    my $r = $ua->get( $url );
    if ( $r->is_success )
    {
        my $jsobj = $r->decoded_content;
        my $obj = $json->decode( $jsobj );
        my $count = 0;

		my $sep = \'|';
		my $tl = Text::Table->new(
            { title => 'ID', align => 'right' }, $sep,
            { title => 'Type', align => 'right' }, $sep,
            { title => 'Name', align => 'right' }, $sep,
            { title => 'Threads', align => 'right' }, $sep,
            { title => 'To-Do', align => 'right' }, $sep,
            { title => 'Preemptive', align => 'right' }, $sep,
            { title => 'Done', align => 'right' }, $sep,
            { title => 'Processing', align => 'right' }, $sep,
            { title => 'Backfill', align => 'right' }
        );

        foreach my $queue ( @{$obj} )
        {
			$tl->add(
                    $queue->{'id'}, 
                    $queue->{'constructor'},
                    $queue->{'name'},
                    $queue->{'maxthreads'},
                    $queue->{'tasks_todo'},
                    $queue->{'preemptive'},
                    $queue->{'tasks_done'},
                    $queue->{'tasks_doing'},
                    $queue->{'tasks_backfill'} );
        }
        #print $t1->draw;
		print $tl->title;
		print $tl->rule('-', '+');
		print $tl->body;
        print "\n$count total queues.\n";
    }
}


sub reloadqueues
{
    my $params = shift;
    my $ua = LWP::UserAgent->new;
    my $url = api_url( $params ) . '/reload-queues-json';
    
    my $r = $ua->get( $url );
    if ( $r->is_success )
    {
        my $jsobj = $r->decoded_content;
        my $obj = $json->decode( $jsobj );
        print Dumper( $obj ). "\n";
    }
    else
    {
        print "Unable to connect to $url!\n";
    }
}



sub queue_set
{
    my $params = shift;
    my $url = api_url . '/set-queue-attr-json';
    my $lwp = LWP::UserAgent->new;
    my $r = $lwp->post( $url,
                        [
                            'queueid'		=> $params->{ 'queueid' },
                            'attr'		=> $params->{ 'key' },
                            'value'		=> $params->{ 'value' },
                        ]
                      );

    if ( $r->is_success )
    {
        my $obj = $json->decode( $r->decoded_content );
        return if $obj->{'success'};
        print "Couldn't set queue attribute: " . $obj->{'error'} . "\n";
    }
    else
    {
        print "Unable to connect to: $url\n";
    }
}


sub queue_start
{
    my $params = shift;
    my $url = api_url . '/start-queue-json';
    my $lwp = LWP::UserAgent->new;
    my $r = $lwp->post( $url,
                        [
                            'type'		=> $params->{ 'type' },
                            'name'		=> $params->{ 'name' },
                        ]
                      );
    if ( $r->is_success )
    {
        my $obj = $json->decode( $r->decoded_content );
        if ( $obj->[0] == 1 )
        {
            print "New Queue #$obj->[1]\n";
            return;
        }
        else
        {
            print "Couldn't create queue:  $obj->[1]\n";
        }
    }
    else
    {
        print "Unable to connect to:  $url\n";
    }
}


sub queue_task
{
    my $params = shift;
    my $url = api_url . '/queue-create-tasks-json';
    my $lwp = LWP::UserAgent->new;
    my $r = $lwp->post( $url,
                        [
                            'queueid'		=> $params->{ 'queueid' },
                            'object'		=> $params->{ 'object' },
                        ]
                      );
    if ( $r->is_success )
    {
        my @ret = @{ $json->decode($r->decoded_content) };
        print $r->decoded_content . "\n";
#        print "New task #$ret[2]\n";
    }
    else
    {
        print "Unable to connect to:  $url\n";
    }
}


sub queue_tasks
{
    my $params = shift;
    my $url = api_url . '/queue-create-tasks-from-users-json';
    my $lwp = LWP::UserAgent->new;
    my $r = $lwp->post( $url,
                        [
                            'queueid'		=> $params->{ 'queueid' },
                            'group'		=> $params->{ 'group' },
                            'filter'		=> $params->{ 'filter' },
                            'columns'		=> $params->{ 'columns' },
                        ]
                      );
    if ( $r->is_success )
    {
        print $r->decoded_content;
#        my @ret = @{ $json->decode($r->decoded_content) };
#        print "New task #$ret[2]\n";
    }
    else
    {
        print "Unable to connect to:  $url\n";
    }
}


sub user_groups
{
    my $params = shift;
    my $url = api_url . '/list-user-groups-json';
    my $lwp = LWP::UserAgent->new;
    my $r = $lwp->post( $url );
    if ( $r->is_success )
    {
        my $obj = $json->decode( $r->decoded_content );
        foreach my $o (@{$obj})
        {
            print "$o\n";
        }
    }
    else
    {
        print "Unable to connect to:  $url\n";
    }
}


sub user_list
{
    my $params = shift;
    my $url = api_url . '/list-users-json';
    my $lwp = LWP::UserAgent->new;
    my $r = $lwp->post( $url,
                        [
                            'group'		=> $params->{ 'group' },
                            'filter'		=> $params->{ 'filter' },
                        ] 
                      );
    if ( $r->is_success )
    {
        my $obj = $json->decode( $r->decoded_content );
        my $first = 1;
        foreach my $username (sort keys %{ $obj })
        {
            my $user = $obj->{ $username };
            if ( $first )
            {
                $first = 0;
                foreach my $col (sort keys %{ $user })
                {
                    print "$col\t";
                }
                print "\n";
            }
            foreach my $col (sort keys %{ $user })
            {
                print "$user->{$col}\t";
            }
            print "\n";
        }
    }
    else
    {
        print "Unable to connect to:  $url\n";
    }
}


sub user_add
{
    warn "user_add\n";
    my $params = shift;
    my $url = api_url . '/add-users-json';
    my $lwp = LWP::UserAgent->new;
    warn "Posting...\n";
    my $r = $lwp->post( $url,
                        [
                            'group'		=> $params->{ 'group' },
                            'users'		=> $json->encode( $params->{'users'} ),
                            'users_csv'		=> $params->{ 'users_csv' },
                        ] 
                      );
    if ( $r->is_success )
    {
        print $r->decoded_content;
#        my $obj = $json->decode( $r->decoded_content );
    }
    else
    {
        print "Unable to connect to:  $url\n";
    }
}


sub user_set
{
    my $params = shift;
    my $url = api_url . '/set-user-json';
    my $lwp = LWP::UserAgent->new;
    my $r = $lwp->post( $url,
                        [
                            'group'		=> $params->{ 'group' },
                            'id'		=> $params->{ 'username' },
                            'object'		=> $json->encode( $params->{'user'} ),
                        ] 
                      );
    if ( $r->is_success )
    {
        print $r->decoded_content;
#        my $obj = $json->decode( $r->decoded_content );
    }
    else
    {
        print "Unable to connect to:  $url\n";
    }
}


sub queue_types
{
    my $params = shift;
    my $url = api_url . '/queue-prototypes-json';
    my $lwp = LWP::UserAgent->new;
    my $r = $lwp->post( $url );
    if ( $r->is_success )
    {
#        print $r->decoded_content;
        my $obj = $json->decode( $r->decoded_content );
        my $text = join( "\n", keys %{$obj} );
        print $text . "\n";
    }
    else
    {
        print "Unable to connect to:  $url\n";
    }
}


sub queue_search
{
    my $params = shift;
    my $url = api_url . '/search-tasks-json';
    my $lwp = LWP::UserAgent->new;
    my $r = $lwp->post( $url,
                        [
                            'queue'		=> $params->{ 'queue' },
                            'filter'		=> $params->{ 'filter' },
                        ] 
                      );
    if ( $r->is_success )
    {
        print $r->decoded_content;
#        my $obj = $json->decode( $r->decoded_content );
    }
    else
    {
        print "Unable to connect to:  $url\n";
    }
}


my ( $ret, $params ) = parse_arguments;
if ( $ret == 0 )
{
    exit( 1 );
}
elsif ( $ret == -1 )
{
    print $USAGE;
    exit( 0 );
}

if ( $params->{'help'} )
{
    print $USAGE;
    exit( 0 );
}


my $func = $params->{ 'execute' };
&$func( $params );
