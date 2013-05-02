=head1 NAME

HuGTFS::FeedManager::Debrecen - HuGTFS feed manager for download + merging existing Debrecen GTFS data with OSM

=head1 SYNOPSIS

	use HuGTFS::FeedManager::Debrecen;

=head1 DESCRIPTION

=head1 METHODS

=cut

package HuGTFS::FeedManager::Debrecen;

use 5.14.0;
use utf8;
use strict;
use warnings;

use Mouse;

extends 'HuGTFS::FeedManager::GTFS';
__PACKAGE__->meta->make_immutable;

my $log = Log::Log4perl->get_logger(__PACKAGE__);

my $agencies = {
	'HV_DB'        => 'HAJDU-VOLAN-DEBRECEN',
	'KT_DB'        => 'KOMAROMI-TARSA-DEBRECEN',
	'TESCO'        => 'TESCO-DEBRECEN',
	'DKV-DEBRECEN' => 'DKV',
};

after 'fixup_agency' => sub {
	my ($self, $agency) = @_;
	$agency->{agency_id} =  $agencies->{$agency->{agency_id}} if $agencies->{$agency->{agency_id}};
};

after 'fixup_route' => sub {
	my ($self, $route) = @_;

	$route->{agency_id} = $agencies->{$route->{agency_id}} if $agencies->{$route->{agency_id}};
	$route->{route_text_color} = '000000' if defined $route->{route_text_color} && $route->{route_text_color} eq '0';
};

after 'fixup_stop' => sub {
	my ($self, $stop) = @_;

	delete $stop->{stop_street};
	delete $stop->{stop_angle};
	delete $stop->{stop_shortname};
	delete $stop->{stop_comment};
	delete $stop->{stop_group_id};
};

1;

=head1 COPYRIGHT

Copyright (c) 2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
