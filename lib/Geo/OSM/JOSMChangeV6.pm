#===============================================================================
#
#         FILE:  JOSMChange.pm
#
#  DESCRIPTION:
#
#        FILES:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  Zsombor Welker (flaktack), flaktack@welker.hu
#      COMPANY:
#      VERSION:  1.0
#      CREATED:  10/24/2009 02:10:23 PM
#     REVISION:  ---
#===============================================================================

package Geo::OSM::JOSMChange;

use strict;
use warnings;

use Carp;
use Geo::OSM::EntitiesV6;

sub new
{
	my $class = shift;
	my $self = bless { none => {}, modify => {}, delete => {}, add => {} }, $class;
}

sub xml
{
	my $self = shift;

	my $str = "<?xml version='1.0' encoding='UTF-8'?>\n<osm version='0.6' generator='JOSM'>\n";

	foreach ( values %{ $self->{none} } ) {
		$str .= $_->xml;
	}
	foreach ( values %{ $self->{add} } ) {
		$str .= $_->xml;
	}
	foreach ( values %{ $self->{modify} } ) {
		$str .= $_->xml;
	}
	foreach ( values %{ $self->{delete} } ) {
		$str .= $_->xml;
	}

	return $str . "</osm>";
}

sub _rebless
{
	my ( $self, $object ) = @_;

	return if $object->isa('Geo::OSM::JOSMChange::Entity');

	if ( $object->isa("Geo::OSM::Node") ) {
		bless $object, "Geo::OSM::JOSMChange::Node";
	}
	elsif ( $object->isa("Geo::OSM::Way") ) {
		bless $object, "Geo::OSM::JOSMChange::Way";
	}
	elsif ( $object->isa("Geo::OSM::Relation") ) {
		bless $object, "Geo::OSM::JOSMChange::Relation";
	}
	else {
		croak "Can't rebless $object";
	}
}

sub _add
{
	my ( $self, $action, $object ) = @_;

	croak "can't id: $object" unless ref $object && $object->can('id');

	my $id = $object->type . ":" . $object->id;

	if ( $self->{none}->{$id} && $action ne 'none' ) {
		delete $self->{none}->{$id};
		$self->{$action}->{$id} = $object;
		$object->set_action($action);
		return;
	}

	return
		if $action eq 'none'
			&& ( $self->{add}->{$id} || $self->{modify}->{$id} || $self->{delete}->{$id} );

	return if ( $self->{$action}->{$id} );

	croak "Already present with a different action: $object"
		if ( $self->{node}->{$id}
		|| $self->{add}->{$id}
		|| $self->{modify}->{$id}
		|| $self->{delete}->{$id} );

	$self->{$action}->{$id} = $object;
	$self->_rebless($object);
	$object->set_action($action);
}

sub none
{
	my ($self) = shift;
	$self->_add( 'none', @_ );
}

sub add
{
	my ($self) = shift;
	$self->_add( 'add', @_ );
}

sub modify
{
	my ($self) = shift;
	$self->_add( 'modify', @_ );
}

sub delete
{
	my ($self) = shift;
	$self->_add( 'delete', @_ );
}

package Geo::OSM::JOSMChange::Entity;
our @ISA = qw/Geo::OSM::Entity/;

sub action
{
	my $self = shift;
	return $self->{action};
}

sub set_action
{
	my ( $self, $action ) = @_;
	return $self->{action} = $action;
}

package Geo::OSM::JOSMChange::Node;
our @ISA = qw/Geo::OSM::Node Geo::OSM::JOSMChange::Entity/;

sub xml
{
	my $self   = shift;
	my $str    = "";
	my $writer = $self->_get_writer( \$str );

	$writer->startTag(
		"node",
		id        => $self->id,
		lat       => $self->lat,
		lon       => $self->lon,
		timestamp => $self->timestamp,
		changeset => $self->changeset,
		version   => $self->version,
		$self->action ? ( action => $self->action ) : (),
		$self->uid    ? ( uid    => $self->uid )    : (),
		$self->user   ? ( user   => $self->user )   : (),
		$self->visible ? ( visible => $self->visible ? 'true' : 'false' ) : (),
	);
	$self->tag_xml($writer);
	$writer->endTag("node");
	$writer->end;
	return $str;
}

package Geo::OSM::JOSMChange::Way;
our @ISA = qw/Geo::OSM::Way Geo::OSM::JOSMChange::Entity/;

sub xml
{
	my $self   = shift;
	my $str    = "";
	my $writer = $self->_get_writer( \$str );

	$writer->startTag(
		"way",
		id        => $self->id,
		timestamp => $self->timestamp,
		changeset => $self->changeset,
		version   => $self->version,
		$self->action ? ( action => $self->action ) : (),
		$self->uid    ? ( uid    => $self->uid )    : (),
		$self->user   ? ( user   => $self->user )   : (),
		$self->visible ? ( visible => $self->visible ? 'true' : 'false' ) : (),
	);
	$self->tag_xml($writer);
	for my $node ( @{ $self->nodes } ) {
		$writer->emptyTag( "nd", ref => $node );
	}
	$writer->endTag("way");
	$writer->end;
	return $str;
}

package Geo::OSM::JOSMChange::Relation;
our @ISA = qw/Geo::OSM::Relation Geo::OSM::JOSMChange::Entity/;

sub xml
{
	my $self   = shift;
	my $str    = "";
	my $writer = $self->_get_writer( \$str );

	$writer->startTag(
		"relation",
		id        => $self->id,
		timestamp => $self->timestamp,
		changeset => $self->changeset,
		version   => $self->version,
		$self->action ? ( action => $self->action ) : (),
		$self->uid    ? ( uid    => $self->uid )    : (),
		$self->user   ? ( user   => $self->user )   : (),
		$self->visible ? ( visible => $self->visible ? 'true' : 'false' ) : (),
	);
	$self->tag_xml($writer);

	# Write members
	foreach my $member ( @{ $self->{members} } ) { $member->_xml($writer) }
	$writer->endTag("relation");
	$writer->end;
	return $str;
}
