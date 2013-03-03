
=head1 NAME

HuGTFS::FeedManager::BKV - HuGTFS feed manager for download + merging existing BKV GTFS data with OSM

=head1 SYNOPSIS

	use HuGTFS::FeedManager::BKV;

=head1 DESCRIPTION

=head1 METHODS

=cut

package HuGTFS::FeedManager::BKV;

use 5.14.0;
use utf8;
use strict;
use warnings;

use Mouse;

extends 'HuGTFS::FeedManager::GTFS';
__PACKAGE__->meta->make_immutable;

my $log = Log::Log4perl->get_logger(__PACKAGE__);

=head2 parse

=cut

override 'trip_shape_strategy' => sub {
	my ( $self, $route, $trip ) = @_;

	return 'relations' if $route->{route_type} eq 'ferry';

	return 'shapefinder';
};

after 'fixup_agency' => sub {
	my ($self, $agency) = @_;
	$agency->{agency_id} = "BKV" if $agency->{agency_id} eq "BKK";
};

after 'fixup_route' => sub {
	my ($self, $route) = @_;

	$route->{agency_id} = "BKV" if $route->{agency_id} eq "BKK";

	if ( $route->{route_id} =~ m/^6\d{3}$/) {
		$route->{route_type} = 'light_rail';
	}
	if ( $route->{route_id} =~ m/^\d{3}7$/ && $route->{route_short_name} =~ m/^\d+$/) {
		$route->{route_short_name} .= 'N';
	}
	if ( $route->{route_id} =~ m/^\d{3}8$/ && $route->{route_short_name} =~ m/^\d+$/) {
		$route->{route_short_name} .= 'G';
	}

	if ( $route->{route_short_name} =~ m/^(70|72|73|74|74A|75|76|77|78|79|80|80A|81|82|83)$/ ) {
		$route->{route_type} = 'trolleybus';
	}
};

after 'fixup_trip' => sub {
	my ($self, $trip) = @_;

	if ( $trip->{route_id} eq '3600' || $trip->{route_id} =~ m/^6\d{3}$/ ) {
		$trip->{trip_bikes_allowed} = 2;
	}
	else {
		$trip->{trip_bikes_allowed} = 1;
	}

	delete $trip->{trips_bkk_ref};
};

after 'fixup_stop' => sub {
	my ($self, $stop) = @_;

	state $default_zone = 'BUDAPEST';
	state $zones        = {
		(
			map { $_ => 'BUDAKESZI' }
				qw/009438 009439 009440 009441 009442 009443 F00115 F00116 F04682 F04683/,
				qw/F04684 F04685 F04708 F04709 F04733 F04734 F04788 F04789 F04790/,
		),
		(
			map { $_ => 'BUDAORS' }
				qw/008339 008462 008598 009085 009589 011327 F01910 F01911 F04710 F04711/,
				qw/F04712 F04713 F04714 F04715 F04716 F04717 F04719 F04720 F04721 F04722/,
				qw/F04724 F04725 F04726 F04727 F04728 F04729 F04730 F04731 F04732 F04735/,
				qw/F04736 F04737 F04738 F04739 F04740 F04791 F04792 F04795 F04796 F04801/,
				qw/F04802 F04803 F04804 F04805 F04806 F04807 F04808 F04809 F04810 F04811/,
				qw/F04829 F04830 F04833 F04834 F04835 F04836 F04837 F04838/,
		),
		(
			map { $_ => 'BUDAORS,BUDAPEST' }
				qw/F01880 F01881 F01882 F01883 F01884 F01886 F01887 F01906 F01907 F02069/,
				qw/F02070/,
		),
		( map { $_ => 'BUDAORS,TOROKBALINT' } qw/008846 008847 F04741 F04742/, ),
		(
			map { $_ => 'DIOSD' }
				qw/008479 008480 009094 009095 009096 009097 009098 009099 009100 009101/,
				qw/009102 009103 009104 009105 009301 F04767 F04768 F04769 F04770 F04771/,
				qw/F04772 F04773 F04816/,
		),
		(
			map { $_ => 'GYAL' }
				qw/008548 008549 008550 008551 008552 008553 009192 009193 009194 009195/,
				qw/009196 009197 009198 009199 009200 009201 009202 009203 009204 009205/,
				qw/009206 009207 F04600 F04601 F04602 F04603 F04604 F04605 F04606 F04647/,
				qw/F04648 F04649 F04650 F04651 F04652/,
		),
		(
			map { $_ => 'NAGYKOVACSI' }
				qw/031884 F00387 F04777 F04778 F04779 F04780 F04781 F04782 F04783 F04784/,
				qw/F04785 F04786 F04821 F04822 F04823 F04824 F04825 F04826 F04827 F04828/,
		),
		(
			map { $_ => 'PECEL' }
				qw/F04578 F04579 F04580 F04581 F04582 F04583 F04585 F04586 F04587 F04588/,
				qw/F04589 F04590 F04591 F04592 F04593 F04594 F04595 F04643 F04644 F04645/,
				qw/F04646/,
		),
		(
			map { $_ => 'PILISBOROSJENO' }
				qw/009065 009066 009067 F00433 F00434 F04774 F04775 F04776 F04817 F04818/,
				qw/F04819 F04820/,
		),
		(
			map { $_ => 'SOLYMAR' }
				qw/F00117 F00118 F04696 F04697 F04698 F04699 F04700 F04701 F04702 F04703/,
				qw/F04704 F04705 F04706 F04707 F04797 F04798 F04799 F04800 F04831 F04832/,
		),
		(
			map { $_ => 'TOROKBALINT' }
				qw/008317 008318 008319 008320 008322 008323 008324 008325 008326 008328/,
				qw/008329 008330 008331 008332 008333 008345 F04743 F04744 F04745 F04746/,
				qw/F04747 F04748 F04749 F04750 F04751 F04752 F04753 F04754 F04755 F04756/,
				qw/F04757 F04758 F04759 F04761 F04762 F04763 F04764 F04765 F04812 F04813/,
				qw/F04814 F04815/,
		),
		(
			map { $_ => 'HEV' }
				qw/009272 009273 009276 F04607 F04608 F04609 F04610 F04611 F04612 F04613/,
				qw/F04614 F04615 F04616 F04617 F04618 F04619 F04620 F04621 F04622 F04623/,
				qw/F04624 F04625 F04626 F04627 F04628 F04629 F04630 F04631 F04632 F04633/,
				qw/F04634 F04635 F04636 F04638 F04655 F04656 F04657 F04658 F04659 F04660/,
				qw/F04661 F04662 F04663 F04664 F04665 F04668 F04669 F04670 F04671 F04672/,
				qw/F04673 F04674 F04675 F04676 F04677 F04679 F04688 F04689 F04690 F04691/,
				qw/F04692 F04693 F04694 F04695 F04793 F04794/,
		),
		(
			map { $_ => 'BUDAPEST,HEV' }
				qw/F00471 F00472 F03411 F03412 F03421 F03422 F04548 F04549/,
		),
	};

	$stop->{zone_id}        = $zones->{ $stop->{stop_code} } || $default_zone;
	$stop->{parent_station} = undef;
};

# Add Sikló & Libegő
after 'augment' => sub {
	my ($self, $dumper) = @_;

	$dumper->dump_route($_)
		for (
		{
			route_id         => 7001,
			agency_id        => 'BKV',
			route_short_name => undef,
			route_long_name  => 'Budavári Sikló',
			route_desc       => undef,
			route_type       => 'funicular',
			route_color      => undef,
			route_text_color => undef,
		},

		{
			route_id         => 7002,
			agency_id        => 'BKV',
			route_short_name => undef,
			route_long_name  => 'Zugligeti Libegő',
			route_desc       => undef,
			route_type       => 'gondola',
			route_color      => undef,
			route_text_color => undef,
		}
		);

	$dumper->dump_calendar( HuGTFS::Cal->find('NAPONTA')->dump() );

	$dumper->dump_trip($_)
		for (
		{
			trip_id               => 'SIKLO-1',
			route_id              => '7001',
			service_id            => 'NAPONTA',
			direction_id          => 'outbound',
			trip_headsign         => 'Szent György tér',
			wheelchair_accessible => 1,
			stop_times    => [
				{
					stop_id        => 'SIKLO-ALSO',
					arrival_time   => '00:00:00',
					departure_time => '00:00:00',
				},
				{
					stop_id        => 'SIKLO-FELSO',
					arrival_time   => '00:02:30',
					departure_time => '00:02:30',
				},
			],
			frequencies => [
				{
					start_time   => '07:30:00',
					end_time     => '22:00:00',
					headway_secs => '450',
					exact_times  => '0'
				}
			],
			shape => {
				shape_id     => 'SHP-SIKLO-1',
				shape_points => [
					{ shape_pt_lat => 47.497890, shape_pt_lon => 19.039816, },
					{ shape_pt_lat => 47.497631, shape_pt_lon => 19.038432, },
				],
			},
		},
		{
			trip_id               => 'SIKLO-2',
			route_id              => '7001',
			service_id            => 'NAPONTA',
			direction_id          => 'inbound',
			trip_headsign         => 'Clark Ádám tér',
			wheelchair_accessible => 1,
			stop_times    => [
				{
					stop_id        => 'SIKLO-FELSO',
					arrival_time   => '00:00:00',
					departure_time => '00:00:00',
				},
				{
					stop_id        => 'SIKLO-ALSO',
					arrival_time   => '00:02:30',
					departure_time => '00:02:30',
				},
			],
			frequencies => [
				{
					start_time   => '07:30:00',
					end_time     => '22:00:00',
					headway_secs => '450',
					exact_times  => '0'
				}
			],
			shape => {
				shape_id     => 'SHP-SIKLO-2',
				shape_points => [
					{ shape_pt_lat => 47.497631, shape_pt_lon => 19.038432, },
					{ shape_pt_lat => 47.497890, shape_pt_lon => 19.039816, },
				],
			},
		},
		{
			trip_id       => 'LIBEGO-1',
			route_id      => '7002',
			service_id    => 'NAPONTA',
			direction_id  => 'outbound',
			trip_headsign => 'János-hegy',
			wheelchair_accessible => 2,
			stop_times    => [
				{
					stop_id        => 'LIBEGO-ALSO',
					arrival_time   => '00:00:00',
					departure_time => '00:00:00',
				},
				{
					stop_id        => 'LIBEGO-FELSO',
					arrival_time   => '00:12:00',
					departure_time => '00:12:00',
				},
			],
			frequencies => [
				{
					start_time   => '09:30:00',
					end_time     => '16:00:00',
					headway_secs => '60',
					exact_times  => '0'
				}
			],
			shape => {
				shape_id     => 'SHP-LIBEGO-1',
				shape_points => [
					{ shape_pt_lat => 47.516646, shape_pt_lon => 18.974521 },
					{ shape_pt_lat => 47.515849, shape_pt_lon => 18.960519 },
				],
			},
		},
		{
			trip_id       => 'LIBEGO-2',
			route_id      => '7002',
			service_id    => 'NAPONTA',
			direction_id  => 'inbound',
			trip_headsign => 'Zugliget',
			wheelchair_accessible => 2,
			stop_times    => [
				{
					stop_id        => 'LIBEGO-FELSO',
					arrival_time   => '00:00:00',
					departure_time => '00:00:00',
				},
				{
					stop_id        => 'LIBEGO-ALSO',
					arrival_time   => '00:12:00',
					departure_time => '00:12:00',
				},
			],
			frequencies => [
				{
					start_time   => '09:30:00',
					end_time     => '16:00:00',
					headway_secs => '60',
					exact_times  => '0'
				}
			],
			shape => {
				shape_id     => 'SHP-LIBEGO-2',
				shape_points => [
					{ shape_pt_lat => 47.515849, shape_pt_lon => 18.960519 },
					{ shape_pt_lat => 47.516646, shape_pt_lon => 18.974521 },
				],
			},
		},
		);

	$dumper->dump_stop($_)
		for (
		{
			stop_id             => 'SIKLO-ALSO',
			stop_name           => 'Clark Ádám tér',
			stop_code           => undef,
			stop_lat            => 47.49789,
			stop_lon            => 19.039816,
			zone_id             => 'SIKLO',
			wheelchair_boarding => 1,
		},
		{
			stop_id             => 'SIKLO-FELSO',
			stop_name           => 'Szent György tér',
			stop_code           => undef,
			stop_lat            => 47.497631,
			stop_lon            => 19.038432,
			zone_id             => 'SIKLO',
			wheelchair_boarding => 1,
		},

		{
			stop_id             => 'LIBEGO-ALSO',
			stop_name           => 'Zugliget',
			stop_code           => undef,
			stop_lat            => 47.516646,
			stop_lon            => 18.974521,
			zone_id             => 'LIBEGO',
			wheelchair_boarding => 2,
		},
		{
			stop_id             => 'LIBEGO-FELSO',
			stop_name           => 'János-hegy',
			stop_code           => undef,
			stop_lat            => 47.515849,
			stop_lon            => 18.960519,
			zone_id             => 'LIBEGO',
			wheelchair_boarding => 2,
		}
		);
};

1;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
