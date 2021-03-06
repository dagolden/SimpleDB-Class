package SimpleDB::Class::ResultSet;

=head1 NAME

SimpleDB::Class::ResultSet - An iterator of items from a domain.

=head1 DESCRIPTION

This class is an iterator to walk to the items passed back from a query. 

B<Warning:> Once you have a result set and you start calling methods on it, it will begin iterating over the result set. Therefore you can't call both C<next> and C<search>, or any other combinations of methods on an existing result set.

B<Warning:> If you call a method like C<search> on a result set which causes another query to be run, know that the original result set must be very small. This is because there is a limit of 20 comparisons per request as a limitation of SimpleDB.

=head1 METHODS

The following methods are available from this class.

=cut

use Moose;
use SimpleDB::Class::SQL;

#--------------------------------------------------------

=head2 new ( params )

Constructor.

=head3 params

A hash.

=head4 simpledb

Required. A L<SimpleDB::Class> object.

=head4 item_class

Required. A L<SimpleDB::Class::Item> subclass name.

=head4 result

A result as returned from the send_request() method from L<SimpleDB::Class::HTTP>. Either this or a where is required.

=head4 where

A where clause as defined in L<SimpleDB::Class::SQL>. Either this or a result is required.

=cut

#--------------------------------------------------------

=head2 item_class ( )

Returns the item_class passed into the constructor.

=cut

has item_class => (
    is          => 'ro',
    required    => 1,
);

with 'SimpleDB::Class::Role::Itemized';

#--------------------------------------------------------

=head2 where ( )

Returns the where passed into the constructor.

=cut

has where => (
    is          => 'ro',
    isa         => 'HashRef',
);

#--------------------------------------------------------

=head2 simpledb ( )

Returns the simpledb passed into the constructor.

=cut

has simpledb => (
    is          => 'ro',
    required    => 1,
);

#--------------------------------------------------------

=head2 result ( )

Returns the result passed into the constructor, or the one generated by fetch_result() if a where is passed into the constructor.

=head2 has_result () 

A boolean indicating whether a result was passed into the constructor, or generated by fetch_result().

=cut

has result => (
    is          => 'rw',
    isa         => 'HashRef',
    predicate   => 'has_result',
    default     => sub {{}},
    lazy        => 1,
);

#--------------------------------------------------------

=head2 iterator ( )

Returns an integer which represents the current position in the result set as traversed by next().

=cut

has iterator => (
    is          => 'rw',
    default     => 0,
);


#--------------------------------------------------------

=head2 fetch_result ( )

Fetches a result, based on a where clause passed into a constructor, and then makes it accessible via the result() method.

=cut

sub fetch_result {
    my ($self) = @_;
    my $select = SimpleDB::Class::SQL->new(
        item_class  => $self->item_class,
        where       => $self->where,
    );
    my %params = (SelectExpression => $select->to_sql);

    # if we're fetching and we already have a result, we can assume we're getting the next batch
    if ($self->has_result) { 
        $params{NextToken} = $self->result->{SelectResult}{NextToken};
    }

    my $result = $self->simpledb->http->send_request('Select', \%params);
    $self->result($result);
    return $result;
}

#--------------------------------------------------------

=head2 count ( [ where ] )

Counts the items in the result set. Returns an integer. 

=head3 where

A where clause as defined by L<SimpleDB::Class::SQL>. If this is specified, then an additional query is executed before counting the items in the result set.

=cut

sub count {
    my ($self, $where) = @_;
    my @ids;
    while (my $item = $self->next) {
        push @ids, $item->id;
    }
    if ($where) {
        my $clauses = { 
            id      => ['in',@ids], 
            '-and'  => $where,
        };
        my $select = SimpleDB::Class::SQL->new(
            item_class  => $self->item_class,
            where       => $clauses,
            output      => 'count(*)',
        );
        my $result = $self->simpledb->http->send_request('Select', {
            SelectExpression    => $select->to_sql,
        });
        return $result->{SelectResult}{Item}{Attribute}{Value};
    }
    else {
        return scalar @ids;
    }
}

#--------------------------------------------------------

=head2 search ( where )

Just like L<SimpleDB::Class::Domain/"search">, but searches within the confines of the current result set, and then returns a new result set.

=head3 where

A where clause as defined by L<SimpleDB::Class::SQL>.

=cut

sub search {
    my ($self, $where) = @_;
    my @ids;
    while (my $item = $self->next) {
        push @ids, $item->id;
    }
    my $clauses = { 
        id      => ['in',@ids], 
        '-and'  => $where,
    };
    return $self->new(
        simpledb    => $self->simpledb,
        item_class  => $self->item_class,
        where       => $clauses,
        );
}

#--------------------------------------------------------

=head2 update ( attributes )

Calls C<update> and then C<put> on all the items in the result set. 

=head3 attributes

A hash reference containing name/value pairs to update in each item.

=cut

sub update {
    my ($self, $attributes) = @_;
    while (my $item = $self->next) {
        $item->update($attributes)->put;
    }
}

#--------------------------------------------------------

=head2 delete ( )

Calls C<delete> on all the items in the result set.

=cut

sub delete {
    my ($self) = @_;
    while (my $item = $self->next) {
        $item->delete;
    }
}

#--------------------------------------------------------

=head2 next () 

Returns the next result in the result set. Also fetches th next partial result set if there's a next token in the first result set and you've iterated through the first partial set.

=cut

sub next {
    my ($self) = @_;
    # get the current results
    my $result = ($self->has_result) ? $self->result : $self->fetch_result;
    my $items = (ref $result->{SelectResult}{Item} eq 'ARRAY') ? $result->{SelectResult}{Item} : [$result->{SelectResult}{Item}];
    my $num_items = scalar @{$items};
    return undef unless $num_items > 0;

    # fetch more results if needed
    my $iterator = $self->iterator;
    if ($iterator >= $num_items) {
        if (exists $result->{SelectResult}{NextToken}) {
            $self->iterator(0);
            $iterator = 0;
            $result = $self->fetch_result;
        }
        else {
            return undef;
        }
    }

    # iterate
    my $item = $items->[$iterator];
    return undef unless defined $item;
    $iterator++;
    $self->iterator($iterator);

    # make the item object
    my $cache = $self->simpledb->cache;
    ## fetch from cache even though we've already pulled it back from the db, because the one in cache
    ## might be more up to date than the one from the DB
    my $attributes = eval{$cache->get($self->item_class->domain_name, $item->{Name})}; 
    my $e;
    if ($e = SimpleDB::Class::Exception::ObjectNotFound->caught) {
        my $itemobj = $self->parse_item($item->{Name}, $item->{Attribute});
        if (defined $itemobj) {
            eval{$cache->set($self->item_class->domain_name, $item->{Name}, $itemobj->to_hashref)};
        }
        return $itemobj;
    }
    elsif ($e = SimpleDB::Class::Exception->caught) {
        warn $e->error;
        return $e->rethrow;
    }
    elsif (defined $attributes) {
        return $self->instantiate_item($attributes,$item->{Name});
    }
    else {
        SimpleDB::Class::Exception->throw(error=>"An undefined error occured while fetching the item from cache.");
    }
}

=head1 LEGAL

SimpleDB::Class is Copyright 2009 Plain Black Corporation (L<http://www.plainblack.com/>) and is licensed under the same terms as Perl itself.

=cut

no Moose;
__PACKAGE__->meta->make_immutable;
