use 5.10.1;
use strict;
use warnings;

package DBIx::Class::Visualizer;

# ABSTRACT: Visualize a DBIx::Class schema
# AUTHORITY
our $VERSION = '0.0100';

use GraphViz2;
use List::Util qw/any/;
use DateTime::Tiny;
use Moo;

#has logger => (
#    is => 'ro',
#    default => sub {
#        my $logger = Log::Handler->new;
#        $logger->add(screen => {
#            maxlevel => 'debug',
#            minlevel => 'error',
#            message_layout => '%m',
#
#        });
#        return $logger;
#    },
#);
has graphviz_config => (
    is => 'ro',
    lazy => 1,
    default => sub {
        my $self = shift;

        return +{
            global => {
                directed => 1,
                smoothing => 'none',
                overlap => 'false',
            },
            graph => {
                rankdir => 'LR',
                splines => 'true',
                label => sprintf ('%s (version %s) rendered by DBIx::Class::Visualizer %s.', ref $self->schema, $self->schema->schema_version, DateTime::Tiny->now->as_string),
                fontname => 'helvetica',
                fontsize => 10,
                labeljust => 'l',
                nodesep => 0.28,
                ranksep => 0.36,
            },
            node => {
                fontname => 'helvetica',
                shape => 'none',
            },
        };
    },
);
has graph => (
    is => 'ro',
    lazy => 1,
    init_arg => undef,
    builder => '_build_graph',
);
sub _build_graph {
    return GraphViz2->new(shift->graphviz_config);
}
has schema => (
    is => 'ro',
    required => 1,
);
has added_relationships => (
    is => 'ro',
    default => sub { +{} },
);
has ordered_relationships => (
    is => 'ro',
    default => sub { [] },
);

sub BUILD {
    my $self = shift;
    my @sources = grep { !/^View::/ } $self->schema->sources;

    foreach my $source_name (sort @sources) {
        $self->add_node($source_name);
    }
    foreach my $source_name (sort @sources) {
        $self->add_edges($source_name);
    }
}

sub svg {
    my $self = shift;

    my $output;
    $self->graph->run(output_file => \$output, format => 'svg');
    return $output;
}

sub add_node {
    my $self = shift;
    my $source_name = shift;

    my $node_name = $self->node_name($source_name);
    my $rs = $self->schema->resultset($source_name)->result_source;

    my @primary_columns = $rs->primary_columns;
    my @foreign_columns = map { keys %{ $_->{'attrs'}{'fk_columns'} } } map { $rs->relationship_info($_) } $rs->relationships;

    my $label_data = {
        source_name => $source_name,
        columns => [],
    };
    for my $column ($rs->columns) {
        my $is_primary = any { $column eq $_ } @primary_columns;
        my $is_foreign = any { $column eq $_ } @foreign_columns;
        push @{ $label_data->{'columns'} } => {
            is_primary => $is_primary,
            is_foreign => $is_foreign,
            name => $column,
        };
    }
    $self->graph->add_node(
        name => $node_name,
        label => $self->create_label_html($node_name, $label_data),
        margin => 0.01,
    );
}

sub add_edges {
    my $self = shift;
    my $source_name = shift;

    my $node_name = $self->node_name($source_name);
    my $rs = $self->schema->resultset($source_name)->result_source;

    RELATION:
    for my $relation_name (sort $rs->relationships) {
        my $relation = $rs->relationship_info($relation_name);
        (my $other_source_name = $relation->{'class'}) =~ s{^.*?::Result::}{};
        my $other_node_name = $self->node_name($other_source_name);

        # Have we already added the edge from the reversed direction?
        next RELATION if exists $self->added_relationships->{"$other_node_name-->$node_name"};

        my $other_rs = $self->schema->resultset($other_source_name)->result_source;
        my $other_relation;

        OTHER_RELATION:
        for my $other_relation_name ($other_rs->relationships) {
            my $relation_to_attempt = $other_rs->relationship_info($other_relation_name);

            my $possibly_original_class = $relation_to_attempt->{'class'} =~ s{^.*?::Result::}{}rg;
            next OTHER_RELATION if $possibly_original_class ne $source_name;
            $other_relation = $relation_to_attempt;
            $other_relation->{'_name'} = $other_relation_name;
        }

        if(!defined $other_relation) {
            warn "! No reverse relationship $source_name <-> $other_source_name";
            next RELATION;
        }

        my $arrowhead = $self->get_arrow_type($relation);
        my $arrowtail = $self->get_arrow_type($other_relation);

        my $headport = ref $relation->{'cond'} eq 'HASH' && scalar keys %{ $relation->{'cond'} } == 1
                             ? (keys %{ $relation->{'cond'} })[0] =~ s{^foreign\.}{}rx
                             : $node_name
                             ;
        my $tailport = ref $relation->{'cond'} eq 'HASH' && scalar keys %{ $relation->{'cond'} } == 1
                             ? (values %{ $relation->{'cond'} })[0] =~ s{^self\.}{}rx
                             : $node_name
                             ;

        $self->graph->add_edge(
            from => "$node_name:$tailport",
            to => "$other_node_name:$headport",
            arrowhead => $arrowhead,
            arrowtail => $arrowtail,
            dir => 'both',
            minlen => 2,
        );

        $self->added_relationships->{ "$node_name-->$other_node_name" } = 1;
        $self->added_relationships->{ "$other_node_name-->$node_name" } = 1;

        push @{ $self->ordered_relationships } => (
            "$node_name-->$other_node_name",
            "$other_node_name-->$node_name"
        );
    }
}

sub get_arrow_type {
    my $self = shift;
    my $relation = shift;

    my $accessor = $relation->{'attrs'}{'accessor'};
    my $is_depends_on = $relation->{'attrs'}{'is_depends_on'};
    my $join_type = exists $relation->{'attrs'}{'join_type'} ? lc $relation->{'attrs'}{'join_type'} : '';

    my $has_many   = $accessor eq 'multi'  && !$is_depends_on && $join_type eq 'left' ? 1 : 0;
    my $belongs_to = $accessor eq 'single' && $is_depends_on  && $join_type eq ''     ? 1 : 0;
    my $might_have = $accessor eq 'single' && !$is_depends_on && $join_type eq 'left' ? 1 : 0;

    return $has_many   ? join ('' => qw/crow none odot/)
         : $belongs_to ? join ('' => qw/none tee/)
         : $might_have ? join ('' => qw/none tee none odot/)
         :               join ('' => qw/dot dot dot/)
         ;

}

sub node_name {
    my $self = shift;
    my $node_name = shift;
    $node_name =~ s{::}{__}g;
    return $node_name;
}
sub port_name {
    my $self = shift;
    my $source_name = shift;
    my $column_name = shift;

    my $node_name = $self->node_name($source_name);
    return "$node_name--$column_name";
}

sub create_label_html {
    my $self = shift;
    my $node_name = shift;
    my $data = shift;

    my $column_html = [];

    for my $column (@{ $data->{'columns'} }) {
        my $clean_column_name = my $column_name = $column->{'name'};

        my $port_name = $self->port_name($node_name, $column_name);

        $column_name = $column->{'is_primary'} ? "<b>$column_name</b>" : $column_name;
        $column_name = $column->{'is_foreign'} ? "<u>$column_name</u>" : $column_name;
        push @{ $column_html } => qq{
            <tr><td align="left" port="$clean_column_name"><font point-size="12">$column_name </font><font color="#ffffff">__</font></td></tr>};
    }
    my $html = qq{
        <<table cellborder="0" cellpadding="1" cellspacing="0" border="1">
            <tr><td bgcolor="#DDDFDD"><font point-size="2"> </font></td></tr>
            <tr><td align="left" bgcolor="#DDDFDD"><b>$data->{'source_name'} </b> <font color="#DDDFDD"> </font></td></tr>
            <tr><td><font point-size="4"> </font></td></tr>
            } . join ('', @{ $column_html }) . qq{
        </table>>
    };

    return $html;
}

1;

__END__

=pod

=head1 SYNOPSIS

    use DBIx::Class::Visualizer;
    use A::DBIx::Class::Schema;

    my $schema = A::DBIx::Class::Schema->connect;
    my $svg = DBIx::Class::Visualizer->new->svg;

=head1 DESCRIPTION

DBIx::Class::Visualizer is a L<GraphViz2> renderer for L<DBIx::Class> schemata.

On the relatively small schemata (about twenty result classes) that I have tried it on it produces reasonably readable graphs. See C<example/visualized.svg> for a
simple example (also available on L<Github|http://htmlpreview.github.io/?https://github.com/Csson/p5-DBIx-Class-Visualizer/blob/master/example/visualized.svg>).

=head1 ATTRIBUTES

=head2 schema

Required instance of a L<DBIx::Class::Schema>.

=head2 graphviz_config

Optional hashref. This hashref is passed to the L<GraphViz2> constructor. Set this if the defaults don't work. Setting this will replace the defaults.

=head2 graph

Can't be passed in the constructor. This contains the constructed L<GraphViz2> object. Use this if you wish to render the visualization manually:

    my $png = DBIx::Class::Visualizer->new(schema => $schema)->graph->run(output_file => 'myschema.png', format => 'png');


=head1 METHODS

=head2 new

The constructor.

=head2 svg

Takes no arguments, and returns the rendered svg document as a string.



=head1 SEE ALSO

=for :list
* L<Mojolicious::Plugin::DbicSchemaViewer> - A L<Mojolicious> plugin that uses this class
* L<GraphViz2::DBI> - A similar idea

=cut
