package Disbatch::Web::Query;

use 5.12.0;
use warnings;

use Cpanel::JSON::XS;
use Scalar::Util qw/ looks_like_number /;

=head1 NAME

Disbatch::Web::Query - Limper-ignorant subs to be used by various packages.

=head1 SYNOPSIS

use Disbatch::Web::Query ':all';

=head1 SUBROUTINES

=over 2

=cut

sub new {
    bless {};
}

=item invalid_params

Parameters: HTTP params C<HASH>, current existsing collection indexes C<HASH>

Returns a list of all params passed which do not match the given indexes. If the list is empty, the params are good.

=cut

sub invalid_params {
    my ($self, $params, $indexes) = @_;
    my @invalid;
    param: for my $param (keys %$params) {
        # 2. if param is part of an index, and every part of the index to its left is a param, it's good
        for my $compound (@$indexes) {
            if (grep { $param eq $_ } @$compound) {
                # we know at least this param is part of this index
                my $good = 1;
                for my $i (@$compound) {
                    $good = 0 unless grep {$i eq $_ } keys %$params;	# part of the prefix is not indexed
                    last if !$good or $i eq $param;
                }
                next param if $good;
            }
        }
        # 3. otherwise, it's bad
        push @invalid, $param;
    }
    @invalid;
}



=item get_indexes

Parameters: C<MongoDB::Collection>.

Returns an C<ARRAY> of current indexes for the given collection. A compound indexes will be an C<ARRAY> element.

=cut

sub get_indexes {
    my ($self, $coll) = @_;
    my @indexes = $coll->indexes->list->all;
    my %names = map { $_->{name} =~ s/_-1(_|$)/_1$1/; $_->{name} => $_ } @indexes;
    my @parsed;
    for my $name (sort keys %names) {
        next if grep { my $qm = quotemeta $name; $_ =~ /^$qm.+/ } keys %names;	# $name is a subset of another index, so ignore it
        my $count = keys %{$names{$name}{key}};
        $names{$name}{name} =~ s/_1$//;
        my @array = split /_1_/, $names{$name}{name}, $count;
        die "Couldn't parse index: ", Cpanel::JSON::XS->new->convert_blessed->allow_blessed->pretty->encode($names{$name}) unless $count == @array;
        $array[0] = '_id' if $array[0] eq '_id_';	# damn mongo for it ending in '_'
        map { $array[$_] = 'id' if $array[$_] eq '_id' } 0..@array-1;	# damn T::T
        push @parsed, \@array;
    }
    \@parsed;
}

=item query

Performs a search.

Parameters: HTTP params (C<HASH>), title (string), OID keys (C<ARRAY>), MongoDB::Collection object,
form action path (string), return raw result (boolean), limit (integer), skip (integer), indexes (C<ARRAY> of arrays).

Form action path should be from C<< request->path >>, and is overridden by the path defined in the schema.

Raw, limit, skip, and indexes key are all optional -- the first three default to 0, and indexes are queried if C<undef>.

Returns the result of the search, or returns the schema of a query.

=cut

sub params_to_query {
    my ($params, $oid_keys) = @_;
    # build a query:
    my @and = ();
    while (my ($k, $v) = each %$params) {
        next if $v eq '';
        if ($k eq 'id' or grep { $k eq $_ } @$oid_keys) {
            # TT doesn't like keys starting with an underscore:
            $k = '_id' if $k eq 'id';
            # change $v into an ObjectId / ARRAY of ObectIds:
            push @and, ref($v) eq 'ARRAY'
                ? { '$or' => [ map { MongoDB::OID->new(value => $_) } @$v ] }
                : { $k => MongoDB::OID->new(value => $v) };
        } elsif (looks_like_number(ref $v eq 'ARRAY' ? $v->[0] : $v)) {	# NOTE: this only checks the first element in @$v
            push @and, ref($v) eq 'ARRAY'
                ? { '$or' => [ map { { $k => 0 + $_ } } @$v ] }
                : { $k => 0 + $v };
        } else {
            push @and, ref($v) eq 'ARRAY'
                ? { '$or' => [ map { { $k => $_ } } @$v ] }
                : { $k => $v };
        }
    }
    @and ? { '$and' => \@and } : {};
}

# get_indexes() invalid_params() params_to_query()
sub query {
    my ($self, $params, $options, $title, $oid_keys, $collection, $path, $raw, $indexes) = @_;
    $options //= {};	# .count .limit .skip .fields
    $title //= '';
    $indexes //= $self->get_indexes($collection);

    my $fields = $options->{'.fields'} || {};
    my $limit = $options->{'.limit'} || 0;
    my $skip = $options->{'.skip'} || 0;

    # FIXME: maybe move this $fields modification to parse_params()
    $fields = Cpanel::JSON::XS->new->utf8->decode($fields) unless ref $fields;	# NOTE: i don't like embedding json in url params	# FIXME: catch and return error
    $fields = { map { $_ => 1 } @$fields } if ref $fields eq 'ARRAY';

    # can only query indexed fields
    my @invalid_params = $self->invalid_params($params, $indexes);
    return { title => $title, path => $path, error => 'non-indexed params given', invalid_params => \@invalid_params, indexes => $indexes } if @invalid_params;

    my $query = params_to_query($params, $oid_keys);

    return { count => $collection->count($query) } if $options->{'.count'};

    # we don't want to return the entire collection
    return { title => $title, path => $path, error => 'refusing to return everything - include one or more indexed search restrictions', indexes => $indexes } unless keys %$query or $limit > 0;

    my @documents = $collection->find($query)->fields($fields)->limit($limit)->skip($skip)->all;

    if ($raw // 0) {
        # FIXME: return [] if no @documents unless $limit == 1, then maybe return undef
        return {} unless @documents;
        return ($limit == 1 ? $documents[0] : \@documents);
    }

    # need allow_blessed for some reason because analysed value is a boolean. convert_blessed messes this up, but is needed for OIDs.
    my $documents = Cpanel::JSON::XS->new->convert_blessed->allow_blessed->pretty->encode($limit == 1 ? $documents[0] : \@documents) if @documents;
    my $result = {
        result  => $documents,
        title   => "$title Results",
        count   => scalar @documents,
        limit   => $limit,
        skip    => $skip,
        params_str  => join('&', map { "$_=$params->{$_}" } keys %$params),	# FIXME: maybe we need $options in here too
        mypath => $path,
    };

    $result->{json} = $documents[0] if $limit == 1;

    return $result;
}

=back

=cut

1;
