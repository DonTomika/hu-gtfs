
=head1 NAME

HuGTFS::Dumper - GTFS dumper used within HuGTFS

=head1 SYNOPSIS

	use HuGTFS::Dumper;

	my $dumper = HuGTFS::Dumper->new
	$dumper->load_data($dir, $prefix);
	$dumper->deinit;
	$dumper->create_zip($file);

=head1 REQUIRES

perl 5.14.0, Text::CSV::Encoded, Archive::ZIP, IO::File

=head1 DESCRIPTION

Simple module to dump perl objects as gtfs/csv data.

=head1 METHODS

=cut

package HuGTFS::Dumper;

use 5.14.0;
use utf8;
use strict;
use warnings qw/ all /;

use Data::Dumper;

use DateTime;
use YAML ();

use IO::File;
use File::Spec qw/ /;
use File::Temp qw/ tempfile tempdir /;
use Text::CSV::Encoded;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );

use Geo::OSM::OsmReaderV6;
use HuGTFS::Util qw/ slurp entity_id /;

use Log::Log4perl;

local $| = 1;

my $log = Log::Log4perl::get_logger(__PACKAGE__);

our $HEADERS = {
	'agency' => [qw/agency_id agency_name agency_url agency_timezone agency_lang agency_phone/],
	'calendar_dates' => [qw/service_id date exception_type/],
	'calendar'       => [
		qw/service_id service_desc monday tuesday wednesday thursday friday saturday sunday start_date end_date/
	],
	'fare_attributes' =>
		[ qw/fare_id price currency_type payment_method transfers transfer_duration/ ],
	'fare_rules'  => [qw/fare_id route_id origin_id destination_id contains_id/],
	'frequencies' => [qw/trip_id start_time end_time headway_secs exact_times/],
	'routes'      => [
		qw/route_id agency_id route_short_name route_long_name route_desc route_type route_url route_color route_text_color route_bikes_allowed/
	],
	'shapes' => [qw/shape_id shape_pt_lat shape_pt_lon shape_pt_sequence shape_dist_traveled/],
	'stops' => [
		qw/stop_id stop_code stop_name stop_desc stop_lat stop_lon zone_id
		   stop_url location_type parent_station stop_osm_entity stop_timezone wheelchair_boarding/
		],
	'stop_times' => [
		qw/trip_id arrival_time departure_time stop_id stop_sequence stop_headsign pickup_type drop_off_type shape_dist_traveled/
	],
	'transfers' => [
		qw/from_stop_id to_stop_id from_route_id to_route_id from_trip_id to_trip_id transfer_type min_transfer_time/
	],
	'trips' => [
		qw/route_id service_id trip_id trip_headsign trip_short_name trip_url direction_id block_id shape_id trip_bikes_allowed wheelchair_accessible/
	],

};

my $FILES = {
	'agency'          => \&dump_agency,
	'calendar_dates'  => \&dump_calendar_date,
	'calendar'        => \&dump_calendar,
	'fare_attributes' => \&dump_fare,
	'fare_rules'      => \&dump_fare_rule,
	'frequencies'     => \&dump_frequency,
	'routes'          => \&dump_route,
	'shapes'          => \&dump_shape,
	'stops'           => \&dump_stop,
	'stop_times'      => \&dump_stop_time,
	'transfers'       => \&dump_transfer,
	'trips'           => \&dump_trip,
};

my $CSV = Text::CSV::Encoded->new(
	{
		encoding_in  => 'utf8',
		encoding_out => 'utf8',
		sep_char     => ',',
		quote_char   => '"',
		escape_char  => '"',
		eol          => "\r\n",
	}
);

=head2 new %options

Create a new dumper.

=head3 options

=over 3

=item prefix

A prefix to be used with gtfs ids.

=item dir

The directory to dump to. Default is a temporary directory.

=back

=cut

sub new
{
	my $class   = shift;
	my %options = @_;

	my $self = {
		IO    => {},
		STOPS => {
			interchanges => {},
			areas        => {},
			stops        => {},
		},
		max_dist_area  => 200,
		prefix         => $options{prefix} || 0,
		dir            => $options{dir} || tempdir( CLEANUP => 1 ),
		route_types    => {},
		trip_route     => {},
		gtfs_to_entity => {},
		agencies       => "",
		README         => undef,
		min_service    => 20910224,
		max_service    => 19910224,
		process_stops  => 0,
		process_shapes => 0,
	};

	$self->{README}      = '';
	$self->{post_README} = <<'EOF';
Hu-GTFS Menetrend
=================

#### magyar személyszállító menetrendek

További információ: [flaktack.net/gtfs-adatok](http://flaktack.net/gtfs-adatok)

A menetrendek GTFS formátumban vannak:
<https://developers.google.com/transit/gtfs/reference>

Feldolgozásuk automatikus, amennyiben hibás az eredmény, ezt a
<contact@transit.flaktack.net> címen lehet jelezni.

**A menetrend adatok tájékoztató jellegűek.** 

LICENC
------------------
[ODbL](http://opendatacommons.org/licenses/odbl/)

[OpenStreetMap](http://www.openstreetmap.org) adatok is felhasználásra kerültek,
melyek &copy; OpenStreetMap contributors, [ODbL](http://opendatacommons.org/licenses/odbl/).

<http://www.openstreetmap.org/copyright>

Általános eltérések a GTFS szabványtól
--------------------------------------

### trips.txt:trip_bikes_allowed

A kerékpár szállítás lehetőségeit ismerteti:

* _0/üres_ ha nem ismert
* _1_      ha nem engedett
* _2_      ha van lehetőség

### trips.txt:trip_url

A járat menetrendjének címe.

### stops.txt:stop_osm_entity

Az OpenStreetMap-ből felhasznált objektum azonosítója.

### calendar.txt:service_desc

EOF

	if ( !-d $self->{dir} ) {
		die "Need an existing directory...";
	}

	return bless $self, $class;
}

=head2 magic $agency_id, $dest

Create an archive from the data in $agency_dir/gtfs at $dest.

=cut

sub magic
{
	my ( $self, $dir, $agency, $dest ) = @_;
	$self->clean_dir;

	if ( -f File::Spec->catfile( $dir, "README.txt" ) ) {
		$self->readme( slurp( File::Spec->catfile( $dir, "README.txt" ) ) );
	}

	$self->load_data( File::Spec->catdir( $dir, 'gtfs' ), $agency );
	$self->deinit;
	$self->create_zip($dest) || die "Can't create gtfs zip";
}

=head2 clean_dir

Empty the directory which will be used for dumping.

=cut

sub clean_dir
{
	my $self = shift;

	unlink $_ for ( glob $self->{dir} . '/*.*' );
}

=head2 process_shapes

Should shapes be processed?

=cut

sub process_shapes
{
	my $self = shift;
	$self->{process_shapes} = 1;
}

=head2 process_stops

Should stops be processed?

=cut

sub process_stops
{
	my $self = shift;
	$self->{process_stops} = 1;
}

=head2 readme

Set the readme data.

=cut

sub readme
{
	my $self = shift;

	$self->{README} .= "\n\n" . shift if $_[0];

	return $self->{README} . $self->{post_README};
}

=head2 deinit

Deinit the dumper.

=cut

sub deinit
{
	&deinit_dumper;
}

sub deinit_dumper()
{
	my $self = shift;

	{
		my $readme = IO::File->new( File::Spec->catfile( $self->{dir}, 'README.txt' ), 'w' );
		$readme->binmode(':utf8');
		$readme->print( $self->{README} . $self->{post_README} );
		undef $readme;
	}
	{
		my ( $date, $min_service, $max_service )
			= ( DateTime->now->datetime(), $self->{min_service}, $self->{max_service} );
		my $l = IO::File->new( File::Spec->catfile( $self->{dir}, 'feed_info.txt' ), 'w' );
		$l->binmode(':utf8');
		$l->print(<<EOF);
feed_publisher_name,feed_publisher_url,feed_lang,feed_start_date,feed_end_date,feed_version
transit.flaktack.net,http://flaktack.net/gtfs-adatok,hu,$min_service,$max_service,transit.flaktack.net$self->{agencies}-$date
EOF
		undef $l;
	}

	for ( keys %{ $self->{IO} } ) {
		undef $self->{IO}->{$_};
	}
}

=head2 create_zip

Create a ZIP archive of the dumped data

=cut

sub create_zip
{
	my ( $self, $file ) = @_;

	my $zip = Archive::Zip->new();
	for ( glob( $self->{dir} . '/*.txt' ), glob( $self->{dir} . '/*.yml' ) ) {
		$zip->addFile( $_, ( File::Spec->splitpath($_) )[-1] );
	}
	unless ( $zip->writeToFileNamed($file) == AZ_OK ) {
		$log->error("Write Error");
		return 0;
	}

	return 1;
}

=head2 load_data $dir, $prefix

Load gtfs/yaml data from the specified directory.

=cut

sub load_data
{
	my ( $self, $dir, $prefix ) = @_;
	return if $dir =~ m/^(?:bin|data|lib|tmp|util)$/;

	# stops gets parsed first, stop_times last -> needed for area type determination
	my @files = sort {
		return -1 if $a eq 'stops';
		return 1  if $b eq 'stops';
		return 1  if $a eq 'stop_times';
		return -1 if $b eq 'stop_times';
		$a cmp $b;
		}
		keys %$FILES;

	if ( $self->{prefix} ) {
		$self->{prefix} = ($prefix || $dir) . '_';
	}

	$self->{route_types}    = {};
	$self->{trip_route}     = {};
	$self->{gtfs_to_entity} = {};

	foreach my $file (@files) {
		my $path = File::Spec->catfile( $dir, $file . '.txt' );
		if ( -e $path ) {

			# read hash from csv
			my $io = IO::File->new( $path, 'r' );
			$CSV->column_names( $CSV->getline($io) );

			# Copy data
			while ( my $row = $CSV->getline_hr($io) ) {
				$FILES->{$file}->( $self, $row );
			}
		}
	}
}

# Add a line of data to specified file
sub put_csv
{
	my ( $self, $file, $data ) = @_;

	$log->confess("No such file: <<$file>>") unless $FILES->{$file};

	unless ( $self->{IO}->{$file} ) {
		my $file_name = File::Spec->catfile( $self->{dir}, "$file.txt" );
		$self->{IO}->{$file} = IO::File->new( $file_name, "w" );
		$log->fatal("Can't open file: <<$file_name>>") unless $self->{IO}->{$file};
		$CSV->print( $self->{IO}->{$file}, $HEADERS->{$file} );
	}

	my $cols = [
		map {
			my $t = defined $data->{$_} ? $data->{$_} : "";
			delete $data->{$_};
			$t
			} @{ $HEADERS->{$file} }
	];

	$CSV->print( $self->{IO}->{$file}, $cols );

	# I like seeing what's being written to files...
	$self->{IO}->{$file}->flush();

	if (%$data) {
		$log->warn( "Unknown keys for <<$file>>: " . join " ", keys %$data );
	}
}

=head2 dump_agency

=cut

sub dump_agency
{
	my ( $self, $agency ) = @_;

	if ( $agency->{routes} ) {
		for ( @{ $agency->{routes} } ) {
			$_->{agency_id} = $agency->{agency_id};
			$self->dump_route($_);
		}

		delete $agency->{routes};
	}

	if ( $agency->{fares} ) {
		for ( @{ $agency->{fares} } ) {
			$self->dump_fare($_);
		}

		delete $agency->{fares};
	}

	$agency->{agency_id} = $self->{prefix} . $agency->{agency_id} if ( $self->{prefix} );

	$self->{agencies} .= '-' . $agency->{agency_id};

	$self->put_csv( 'agency', $agency );
}

=head2 dump_route

=cut

sub dump_route
{
	my ( $self, $route ) = @_;

	$self->{route_types}
		->{ $self->{prefix} ? $self->{prefix} . $route->{route_id} : $route->{route_id} }
		= $route->{route_type};

	if( $route->{agency}) {
		$route->{agency_id} = $route->{agency}->{agency_id};
		$self->dump_agency($route->{agency});
		delete $route->{agency};
	}

	if ( $route->{trips} ) {
		for ( @{ $route->{trips} } ) {
			$_->{route_id} = $route->{route_id};
			$self->dump_trip($_);
		}

		delete $route->{trips};
	}

	$route->{agency_id} = $self->{prefix} . $route->{agency_id} if ( $self->{prefix} );
	$route->{route_id}  = $self->{prefix} . $route->{route_id}  if $self->{prefix};

	if (   $route->{route_type} eq 'tram'
		|| $route->{route_type} eq 'light_rail' )
	{
		$route->{route_type} = 0;
	}
	elsif ( $route->{route_type} eq 'subway' ) {
		$route->{route_type} = 1;
	}
	elsif ($route->{route_type} eq 'rail'
		|| $route->{route_type} eq 'narrow_gauge' )
	{
		$route->{route_type} = 2;
	}
	elsif ( $route->{route_type} eq 'bus' || $route->{route_type} eq 'trolleybus' ) {
		$route->{route_type} = 3;
	}
	elsif ( $route->{route_type} eq 'ferry' ) {
		$route->{route_type} = 4;
	}
	elsif ( $route->{route_type} eq 'cable_car' ) {
		$route->{route_type} = 5;
	}
	elsif ( $route->{route_type} eq 'gondola' ) {
		$route->{route_type} = 6;
	}
	elsif ( $route->{route_type} eq 'funicular' ) {
		$route->{route_type} = 7;
	}

	$self->put_csv( 'routes', $route );
}

=head2 dump_trip

=cut

sub dump_trip
{
	my ( $self, $trip ) = @_;

	if ( $trip->{departures} ) {

		# XXX
	}

	if ( $self->{process_stops} ) {
		$self->{trip_route}
			->{ $self->{prefix} ? $self->{prefix} . $trip->{trip_id} : $trip->{trip_id} }
			= $self->{prefix} ? $self->{prefix} . $trip->{route_id} : $trip->{route_id};
	}

	if ( $trip->{stop_times} ) {
		for ( 0 .. $#{ $trip->{stop_times} } ) {
			$trip->{stop_times}->[$_]->{trip_id}       = $trip->{trip_id};
			$trip->{stop_times}->[$_]->{stop_sequence} = $_ + 1;
			$self->dump_stop_time( $trip->{stop_times}->[$_] );
		}

		delete $trip->{stop_times};
	}

	if ( $trip->{frequencies} ) {
		for ( @{ $trip->{frequencies} } ) {
			$_->{trip_id} = $trip->{trip_id};
			$self->dump_frequency($_);
		}

		delete $trip->{frequencies};
	}

	if ( $trip->{service} ) {
		$trip->{service_id} = $trip->{service}->{service_id};
		$self->dump_calendar( $trip->{service} );
		delete $trip->{service};
	}
	$trip->{service_id} = $self->{prefix} . $trip->{service_id} if $self->{prefix};

	if ( $trip->{shape} ) {
		$trip->{shape_id} = $trip->{shape}->{shape_id};
		$self->dump_shape( $trip->{shape} );
		delete $trip->{shape};
	}
	$trip->{shape_id} = $self->{prefix} . $trip->{shape_id}
		if $self->{prefix} && $trip->{shape_id};

	if ( !$trip->{direction_id} ) {
		$trip->{direction_id} = '';
	}
	elsif ( $trip->{direction_id} eq 'outbound' ) {
		$trip->{direction_id} = 0;
	}
	if ( $trip->{direction_id} eq 'inbound' ) {
		$trip->{direction_id} = 1;
	}

	if($trip->{wheelchair_accessible}) {
		$trip->{wheelchair_accessible} = 1 if $trip->{wheelchair_accessible} eq 'yes';
		$trip->{wheelchair_accessible} = 1 if $trip->{wheelchair_accessible} eq 'limited';
		$trip->{wheelchair_accessible} = 2 if $trip->{wheelchair_accessible} eq 'no';
	}

	$trip->{route_id} = $self->{prefix} . $trip->{route_id} if $self->{prefix};
	$trip->{trip_id}  = $self->{prefix} . $trip->{trip_id}  if $self->{prefix};

	$self->put_csv( 'trips', $trip );
}

=head2 dump_stop

=cut

sub dump_stop
{
	my ( $self, $stop ) = @_;

	# TODO: parent_station / station / halt / ...

	delete $stop->{stop_point_lat};
	delete $stop->{stop_point_lon};

	if($stop->{entrances}) {
		foreach my $entrance (@{$stop->{entrances}}) {
			$entrance->{location_type} = 'entrance' unless $entrance->{location_type};
			$entrance->{parent_station} = $stop->{stop_id} unless $entrance->{parent_station};

			# "sub stations" are dumped after the processing of the parent station
		}
	}

	$stop->{stop_id} = $self->{prefix} . $stop->{stop_id} if $self->{prefix};
	$stop->{parent_station} = $self->{prefix} . $stop->{parent_station}
		if $self->{prefix} && $stop->{parent_station};

	if ( $self->{process_stops} ) {
		state $gen_osm = 0;
		$stop->{stop_osm_entity} = 'gen_osm_' . ( ++$gen_osm ) if !$stop->{stop_osm_entity};

		if ( $stop->{location_type} eq 'station' || $stop->{location_type} eq '1' ) {
			unless ( $self->{STOPS}->{areas}->{ $stop->{stop_osm_entity} } ) {
				$self->{STOPS}->{areas}->{ $stop->{stop_osm_entity} } = {
					id            => $stop->{stop_osm_entity},
					type          => 'stop',
					gtfs_stop_ids => { $stop->{stop_id} => 1 },
					geom          => [ $stop->{stop_lon}, $stop->{stop_lat} ],
					members       => {},
					polygon       => {},
					name          => $stop->{stop_name},
					names         => {
						$stop->{stop_name}             => 1,
						rat_name( $stop->{stop_name} ) => 1
					},
				};
			}
			else {
				my $nstop = $self->{STOPS}->{areas}->{ $stop->{stop_osm_entity} };
				$nstop->{gtfs_stop_ids}->{$stop->{stop_id}} = 1;

				$nstop->{names}->{ $stop->{stop_name} } = 1;
				$nstop->{names}->{ rat_name( $stop->{stop_name} ) } = 1;
			}
		}
		elsif ( $stop->{location_type} eq 'entrance' || $stop->{location_type} eq '2' ) {
			$log->warn(
				"Stop#entrance missing parent_station: $stop->{stop_id} ($stop->{stop_name})")
				unless $stop->{parent_station};

			# ignore in areas
		}
		elsif ( !$stop->{location_type} ) {
			unless ( $self->{STOPS}->{stops}->{ $stop->{stop_osm_entity} } ) {
				$self->{STOPS}->{stops}->{ $stop->{stop_osm_entity} } = {
					id            => $stop->{stop_osm_entity},
					type          => 'stop',
					gtfs_stop_ids => { $stop->{stop_id} => 1 },
					geom          => [ $stop->{stop_lon}, $stop->{stop_lat} ],
					members       => {},
					polygon       => {},
					name          => $stop->{stop_name},
					names         => {
						$stop->{stop_name}             => 1,
						rat_name( $stop->{stop_name} ) => 1
					},
				};
			}
			else {
				my $nstop = $self->{STOPS}->{stops}->{ $stop->{stop_osm_entity} };
				$nstop->{gtfs_stop_ids}->{$stop->{stop_id}} = 1;

				$nstop->{names}->{ $stop->{stop_name} } = 1;
				$nstop->{names}->{ rat_name( $stop->{stop_name} ) } = 1;
			}

			if ( $stop->{parent_station} ) {
				if ( $self->{gtfs_to_entity}->{ $stop->{parent_station} } ) {
					my $area = $self->{STOPS}->{areas}
						->{ $self->{gtfs_to_entity}->{ $stop->{parent_station} } };
					$self->{STOPS}->{stops}->{ $stop->{stop_osm_entity} }->{area} = $area->{id};
					$area->{members}->{$stop->{stop_osm_entity}} = 1;
					$area->{gtfs_stop_ids}->{$stop->{stop_id}} = 1;
				}
				else {
					$log->fatal("Found 'sub station' preceding 'parent station'... $stop->{stop_id} -> $stop->{parent_station}");
					die Dumper($stop);
				}
			}
		}

		$self->{gtfs_to_entity}->{ $stop->{stop_id} } = $stop->{stop_osm_entity};

		delete $stop->{stop_osm_entity} if $stop->{stop_osm_entity} =~ m/^gen_osm/;
	}

	if($stop->{entrances}) {
		# dump entrances after parent station
		foreach my $entrance (@{$stop->{entrances}}) {
			$self->dump_stop( $entrance );
		}

		delete $stop->{entrances};
	}

	if($stop->{location_type}) {
		$stop->{location_type} = 2 if $stop->{location_type} eq 'entrance';
		$stop->{location_type} = 1 if $stop->{location_type} eq 'station';
	}

	if($stop->{wheelchair_boarding}) {
		$stop->{wheelchair_boarding} = 1 if $stop->{wheelchair_boarding} eq 'yes';
		$stop->{wheelchair_boarding} = 1 if $stop->{wheelchair_boarding} eq 'limited';
		$stop->{wheelchair_boarding} = 2 if $stop->{wheelchair_boarding} eq 'no';
	}

	$self->put_csv( 'stops', $stop );
}

=head2 dump_frequency

=cut

sub dump_frequency
{
	my ( $self, $frequency ) = @_;

	$frequency->{trip_id} = $self->{prefix} . $frequency->{trip_id} if $self->{prefix};

	$self->put_csv( 'frequencies', $frequency );
}

=head2 dump_stop_time

=cut

sub dump_stop_time
{
	my ( $self, $stop_time ) = @_;

	if ( $stop_time->{arrival_time} && $stop_time->{arrival_time} =~ m/^[^:]+:[^:]+$/ ) {
		$stop_time->{arrival_time} = $stop_time->{arrival_time} . ':00';
	}
	if ( $stop_time->{departure_time} && $stop_time->{departure_time} =~ m/^[^:]+:[^:]+$/ ) {
		$stop_time->{departure_time} = $stop_time->{departure_time} . ':00';
	}

	$stop_time->{trip_id} = $self->{prefix} . $stop_time->{trip_id} if $self->{prefix};
	$stop_time->{stop_id} = $self->{prefix} . $stop_time->{stop_id} if $self->{prefix};

	if ( $self->{process_stops} && $self->{gtfs_to_entity}->{ $stop_time->{stop_id} } ) {
		$self->{STOPS}->{stops}->{ $self->{gtfs_to_entity}->{ $stop_time->{stop_id} } }->{modes}
			->{ $self->{route_types}->{ $self->{trip_route}->{ $stop_time->{trip_id} } } } = 1;
	}

	$self->put_csv( 'stop_times', $stop_time );
}

=head2 dump_shape

=cut

sub dump_shape
{
	my ( $self, $shape ) = @_;

	$shape->{shape_id} = $self->{prefix} . $shape->{shape_id} if $self->{prefix};

	if ( $shape->{shape_points} ) {
		for ( 0 .. $#{ $shape->{shape_points} } ) {
			$shape->{shape_points}->[$_]->{shape_id}          = $shape->{shape_id};
			$shape->{shape_points}->[$_]->{shape_pt_sequence} = $_ + 1;
			$self->put_csv( 'shapes', $shape->{shape_points}->[$_] );
		}
	}
	else {
		$self->put_csv( 'shapes', $shape );
	}

	delete $shape->{shape_points};
}

=head2 dump_calendar

=cut

sub dump_calendar
{
	my ( $self, $service ) = @_;

	if ( $service->{exceptions} ) {
		for ( sort { $a->{date} <=> $b->{date} } @{ $service->{exceptions} } ) {
			$_->{service_id} = $service->{service_id};
			$self->dump_calendar_date($_);
		}

		delete $service->{exceptions};
	}

	if ( $service->{start_date} < $self->{min_service} ) {
		$self->{min_service} = $service->{start_date};
	}
	if ( $service->{end_date} > $self->{max_service} ) {
		$self->{max_service} = $service->{end_date};
	}

	$service->{service_id} = $self->{prefix} . $service->{service_id} if $self->{prefix};

	$self->put_csv( 'calendar', $service );
}

=head2 dump_calendar_date

=cut

sub dump_calendar_date
{
	my ( $self, $date ) = @_;

	if ( $date->{exception_type} eq 'added' ) {
		$date->{exception_type} = 1;
	}
	elsif ( $date->{exception_type} eq 'removed' ) {
		$date->{exception_type} = 2;
	}

	if ( $date->{date} < $self->{min_service} ) {
		$self->{min_service} = $date->{date};
	}
	if ( $date->{date} > $self->{max_service} ) {
		$self->{max_service} = $date->{date};
	}

	$date->{service_id} = $self->{prefix} . $date->{service_id} if $self->{prefix};

	$self->put_csv( 'calendar_dates', $date );
}

=head2 dump_fare

=cut

sub dump_fare
{
	my ( $self, $fare ) = @_;

	if ( $fare->{payment_method} eq 'onboard' ) {
		$fare->{payment_method} = 0;
	}
	elsif ( $fare->{payment_method} eq 'prepaid' ) {
		$fare->{payment_method} = 1;
	}

	if ( $fare->{rules} ) {
		for ( @{ $fare->{rules} } ) {
			$_->{fare_id} = $fare->{fare_id};
			$self->dump_fare_rule($_);
		}
		delete $fare->{rules};
	}

	$fare->{fare_id} = $self->{prefix} . $fare->{fare_id} if $self->{prefix};

	$self->put_csv( 'fare_attributes', $fare );
}

=head2 dump_fare_rule

=cut

sub dump_fare_rule
{
	my ( $self, $rule ) = @_;

	$rule->{fare_id}  = $self->{prefix} . $rule->{fare_id}  if $self->{prefix};
	$rule->{route_id} = $self->{prefix} . $rule->{route_id} if $self->{prefix};

	$self->put_csv( 'fare_rules', $rule );
}

sub dump_statistics
{
	my $self = shift;

	my $stops = IO::File->new( File::Spec->catfile( $self->{dir}, 'statistics.yml' ), 'w' );
	$stops->binmode(':utf8');
	$stops->print( YAML::Dump shift );
	undef $stops;
}

# Load OSM data for creating stop hierachies & merging stops.
sub load_osm
{
	my $self           = shift;
	my $osmfile        = shift;
	my %tram_platforms = ();
	my %railways       = ();
	my $gen            = 1;
	my $platform_names = {};

	my $pr = sub {
		my $e = shift;

		if (   ( $e->isa("Geo::OSM::Node") && $self->{STOPS}->{stops}->{ 'node_' . $e->id } )
			|| ( $e->isa("Geo::OSM::Way") && $self->{STOPS}->{stops}->{ 'way_' . $e->id } ) )
		{
			my $stop = $self->{STOPS}->{stops}->{ entity_id($e) };
			$stop->{polygon} = { entity_id($e) => 1 };
			$stop->{name}    = $e->tag('name');

			if ( $e->tag('highway') && $e->tag('highway') eq 'bus_stop' ) {
				$stop->{type} = 'bus_stop';
			}
			if ( $e->tag('railway') && $e->tag('railway') eq 'tram_stop' ) {
				$stop->{type} = 'tram_stop';
			}

			if ( $e->tag('railway') && $e->tag('railway') =~ m/halt|station/ ) {
				$railways{ entity_id($e) } = $e->tag('railway');
			}

			for (qw/name alt_name old_name alt_old_name/) {
				my $m = $e->tag($_);
				if ($m) {
					$stop->{names}->{$m} = 1;
					$stop->{names}->{ rat_name($m) } = 1;
				}
			}
		}

		if (   $e->isa("Geo::OSM::Relation")
			&& $e->tag("type")
			&& $e->tag("type") eq 'public_transport'
			&& $e->tag("public_transport") )
		{
			given ( $e->tag('public_transport') ) {
				when (m/^(?:stop|tram_stop|bus_stop|dock|apron)$/) {
					my $stop = $self->{STOPS}->{stops}->{ entity_id($e) };
					return unless $stop;

					$stop->{type} = $e->tag('public_transport');

					my %stoppy;
					foreach my $m ( $e->members ) {
						if ( $m->role eq 'platform' ) {
							$stop->{polygon}->{$m->member_type . '_' . $m->ref} = 1;

							if ( $m->member_type eq 'way' || $m->member_type eq 'relation' ) {
								push @{ $tram_platforms{ entity_id($m) } }, entity_id($e);
							}
						}
						$stoppy{$m->member_type . '_' . $m->ref} = 1 if $m->role eq 'stop';
					}
					unless ( ref $stop->{polygon} && scalar values %{$stop->{polygon}} ) {
						$stop->{polygon} = \%stoppy;
					}

					$stop->{name} = $e->tag('name');
					for (qw/name alt_name old_name alt_old_name/) {
						my $m = $e->tag($_);
						if ($m) {
							$stop->{names}->{$m} = 1;
							$stop->{names}->{ rat_name($m) } = 1;
						}
					}
				}
				when (
					m/^(?:stops|stop_area|railway_station|railway_halt|bus_station|ferry_terminal)$/
					)
				{
					my $area = $self->{STOPS}->{areas}->{ entity_id($e) } || {};

					$area->{id} = entity_id($e);
					$area->{type} = $e->tag('stop_area') || $e->tag('public_transport');

					$area->{names}         ||= {};
					$area->{polygon}       ||= {};
					$area->{members}       ||= {};
					$area->{gtfs_stop_ids} ||= {};

					$area->{name} = $e->tag('name');
					for (qw/name alt_name old_name alt_old_name/) {
						my $m = $e->tag($_);
						if ($m) {
							$area->{names}->{$m} = 1;
							$area->{names}->{ rat_name($m) } = 1;
						}
					}

					foreach my $m ( $e->members ) {
						my $stop = $self->{STOPS}->{stops}->{ entity_id($m) };
						next unless $stop;

						$stop->{area} = $area->{id};

						$area->{members}->{$stop->{id}} = 1;
					}

					return unless scalar values %{ $area->{members} };

					$self->{STOPS}->{areas}->{ $area->{id} } = $area;
				}
				when ("transport_interchange") {
					my $interchange = {
						id            => entity_id($e),
						type          => 'transport_interchange',
						name          => $e->tag('name'),
						names         => {},
						polygon       => {},
						members       => {},
						gtfs_stop_ids => {},
					};

					$interchange->{name} = $e->tag('name');
					for (qw/name alt_name old_name alt_old_name/) {
						my $m = $e->tag($_);
						if ($m) {
							$interchange->{names}->{$m} = 1;
							$interchange->{names}->{ rat_name($m) } = 1;
						}
					}

					foreach my $m ( $e->members ) {
						$interchange->{members}->{entity_id($m)} = 1;
					}

					$self->{STOPS}->{interchanges}->{ entity_id($e) } = $interchange;
				}
			}
		}
	};

	$log->info("Reading osm data [global]: $osmfile");
	unless ( Geo::OSM::OsmReader->init($pr)->load($osmfile) ) {
		$log->logdie("Failed to parse osm file: $osmfile");
	}

	my $pr_platform = sub {
		my $e  = shift;
		my $id = entity_id($e);

		$platform_names->{$id} = $e->tag("name") if $tram_platforms{$id} && $e->tag("name");
	};

	# We go through the OSM data again to see if it contains names for
	# platforms that will be merged. This is useful, because if the stops
	# on the two sides of the platform have different names, than a name
	# may be provided for the actual platform, which hopefully makes more
	# sense.
	$log->info("Reading osm data [platforms]: $osmfile");
	unless ( Geo::OSM::OsmReader->init($pr_platform)->load($osmfile) ) {
		$log->logdie("Failed to parse osm file: $osmfile");
	}

	foreach my $key ( keys %railways ) {
		next if $self->{STOPS}->{stops}->{$key}->{area};

		my $stop = $self->{STOPS}->{stops}->{$key};

		my $area = {%$stop};
		$stop->{id}   = "gen_stop_$gen";
		$stop->{area} = $area->{id};
		$stop->{type} = 'stop';

		$area->{members} = { $stop->{id} => 1 };
		$area->{polygon} = { $area->{id} => 1 };
		$area->{type}    = 'railway_' . $railways{$key};
		$area->{names}   = { %{ $stop->{names} } };
		delete $area->{modes};

		$self->{STOPS}->{stops}->{ $stop->{id} } = $stop;
		$self->{STOPS}->{areas}->{ $area->{id} } = $area;
		delete $self->{STOPS}->{stops}->{ $area->{id} };

		$gen++;
	}

	### Merge stops sharing a (way) platform
	my @purged;
	foreach my $platform ( grep { $#{ $tram_platforms{$_} } > 0 } keys %tram_platforms ) {
		my $super = {
			id            => "gen_stop_$gen",
			geom          => [],
			type          => '',
			name          => undef,
			names         => {},
			gtfs_stop_ids => {},
			polygon       => {},
			area          => undef,
		};
		my ( $base, @minor )
			= map { $self->{STOPS}->{stops}->{$_} } @{ $tram_platforms{$platform} };

		$super->{type}  = $base->{type};
		$super->{geom}  = $base->{geom};
		$super->{name}  = $platform_names->{$platform} || $base->{name};
		$super->{names} = \%{ $base->{names} };
		$super->{names}->{$_} = 1 for ( map { keys %{ $_->{names} } } @minor );
		$super->{gtfs_stop_ids} = {
			map { $_ => 1 }
			map { keys %{ $_->{gtfs_stop_ids} } } ( $base, @minor )
		};
		$super->{polygon} = {
			map { $_ => 1 }
			map { keys %{ $_->{polygon} } } ( $base, @minor )
		};

		$super->{area} = $base->{area};
		if ( $super->{area} ) {
			my $area = $self->{STOPS}->{areas}->{ $super->{area} };

			$area->{gtfs_stop_ids} = {
				map { $_ => 1 }
					( keys %{ $area->{gtfs_stop_ids} }, keys %{ $super->{gtfs_stop_ids} } )
			};

			$area->{polygon}
				= {
					map { $_ => 1 } ( keys %{ $area->{polygon} }, keys %{ $super->{polygon} } )
				};

			$area->{members}->{$super->{id}} = 1;
		}

		for my $s ( $base, @minor ) {
			next unless $s->{area};

			my $area = $self->{STOPS}->{areas}->{ $s->{area} };
			delete $area->{members}->{$s->{id}};
			delete $area->{polygon}->{$s->{id}};
		}

		push @purged, map { $_->{id} } ( $base, @minor );

		$self->{STOPS}->{stops}->{ $super->{id} } = $super;
		$gen++;
	}
	delete $self->{STOPS}->{stops}->{$_} for (@purged);

	foreach my $area ( values %{ $self->{STOPS}->{areas} } ) {
		$area->{names} = {
			%{ $area->{names} },
			( map { %{ $self->{STOPS}->{stops}->{$_}->{names} } } keys %{ $area->{members} } )
		};

		$area->{members} = { %{ $area->{members} } };

		$area->{gtfs_stop_ids} = {
			map { $_ => 1 }
				map { keys %{ $self->{STOPS}->{stops}->{$_}->{gtfs_stop_ids} } }
				keys %{ $area->{members} }
		};

		$area->{polygon} = {
			map { $_ => 1 }
				map { keys %{ $self->{STOPS}->{stops}->{$_}->{polygon} } }
				keys %{ $area->{members} }
		};
	}

	foreach my $interchange ( values %{ $self->{STOPS}->{interchanges} } ) {
		$interchange->{members}
			= { map { $_ => 1 } (grep { defined $self->{STOPS}->{areas}->{$_} } keys %{ $interchange->{members} }) };

		unless ( scalar keys %{ $interchange->{members} } ) {
			delete $self->{STOPS}->{interchanges}->{ $interchange->{id} };
			next;
		}

		$interchange->{names} = {
			%{ $interchange->{names} },
			(
				map { %{ $self->{STOPS}->{areas}->{$_}->{names} } } keys %{ $interchange->{members} }
			)
		};

		$interchange->{gtfs_stop_ids} = {
			map { $_ => 1 }
				map { keys %{ $self->{STOPS}->{areas}->{$_}->{gtfs_stop_ids} } }
				keys %{ $interchange->{members} }
		};

		$interchange->{polygon} = {
			map { $_ => 1 }
				map { keys %{ $self->{STOPS}->{areas}->{$_}->{polygon} } }
				keys %{ $interchange->{members} }
		};
	}

	eval "use Algorithm::QuadTree; use Geo::Distance; 'true';"
		or $log->fatal("Missing modules: $@");

	my $dist  = Geo::Distance->new;
	my $index = Algorithm::QuadTree->new(
		-xmin  => 16.03,
		-xmax  => 22.96,
		-ymin  => 45.71,
		-ymax  => 48.57,
		-depth => 6,
	);

	# create an index for stops
	# foreach stop -> if not in a stop_area relation
	foreach my $stop ( grep { !$_->{area} } values %{ $self->{STOPS}->{stops} } ) {
		$index->add( $stop->{id}, @{ $stop->{geom} }[ 0, 1, 0, 1 ] );
	}

	foreach my $stop ( grep { !$_->{area} } values %{ $self->{STOPS}->{stops} } ) {
		my $area;

		foreach my $sid (
			grep { defined $self->{STOPS}->{stops}->{$_}->{area} } @{
				$index->getEnclosedObjects(
					$stop->{geom}[0] - 0.005,
					$stop->{geom}[1] - 0.005,
					$stop->{geom}[0] + 0.005,
					$stop->{geom}[1] + 0.005,
				)
			}
			)
		{
			my $astop = $self->{STOPS}->{stops}->{$sid};
			my $aarea = $self->{STOPS}->{areas}->{ $astop->{area} };

			if ( grep { defined $aarea->{names}->{$_} } keys %{ $stop->{names} } ) {
				if (
					$dist->distance( 'meter',
						@{ $astop->{geom} }[ 0, 1 ] => @{ $stop->{geom} }[ 0, 1 ] )
					< $self->{max_dist_area}
					)
				{
					$area = $aarea;
					last;
				}
			}

		}

		unless ($area) {
			$area = {
				id            => 'gen_area_' . $gen,
				type          => 'stops',
				name          => $stop->{name},
				names         => {},
				polygon       => {},
				members       => {},
				gtfs_stop_ids => {},
			};

			$self->{STOPS}->{areas}->{ $area->{id} } = $area;
			$gen++;
		}

		$stop->{area} = $area->{id};

		$area->{names}->{$_} = 1 for keys %{ $stop->{names} };
		$area->{members}->{$stop->{id}} = 1;
		if($stop->{polygon}) {
			$area->{polygon}->{$_} = 1 for keys %{ $stop->{polygon} };
		}
		$area->{gtfs_stop_ids}->{$_} = 1 for keys %{ $stop->{gtfs_stop_ids} };
	}

	### Merge nearby generated areas
	foreach my $stop ( values %{ $self->{STOPS}->{stops} } ) {
		my ( $keep_area, $merge_area );

		foreach my $sid (
			grep { defined $self->{STOPS}->{stops}->{$_}->{area} } @{
				$index->getEnclosedObjects(
					$stop->{geom}[0] - 0.005,
					$stop->{geom}[1] - 0.005,
					$stop->{geom}[0] + 0.005,
					$stop->{geom}[1] + 0.005,
				)
			}
			)
		{
			my $astop = $self->{STOPS}->{stops}->{$sid};
			my $aarea = $self->{STOPS}->{areas}->{ $astop->{area} };

			if ( grep { defined $aarea->{names}->{$_} } keys %{ $stop->{names} } ) {
				if (
					$dist->distance( 'meter',
						@{ $astop->{geom} }[ 0, 1 ] => @{ $stop->{geom} }[ 0, 1 ] )
					< $self->{max_dist_area}
					)
				{

					#$area = $aarea;
					last;
				}
			}

		}
	}

	foreach my $stop ( values %{ $self->{STOPS}->{stops} } ) {
		$stop->{gtfs_stop_ids} = [ keys %{ $stop->{gtfs_stop_ids} } ];
		$stop->{members} = [ keys %{ $stop->{members} } ];
		$stop->{polygon} = [ keys %{ $stop->{polygon} } ];
	}

	foreach my $area ( values %{ $self->{STOPS}->{areas} } ) {
		$area->{gtfs_stop_ids} = [ keys %{ $area->{gtfs_stop_ids} } ];
		$area->{members} = [ keys %{ $area->{members} } ];
		$area->{polygon} = [ keys %{ $area->{polygon} } ];
	}

	foreach my $interchange ( values %{ $self->{STOPS}->{interchanges} } ) {
		$interchange->{gtfs_stop_ids} = [ keys %{ $interchange->{gtfs_stop_ids} } ];
		$interchange->{members} = [ keys %{ $interchange->{members} } ];
		$interchange->{polygon} = [ keys %{ $interchange->{polygon} } ];
	}
}

=head2 postprocess_stops $osmfile

Create a stops.yml file containing merged stop/area/interchange relations.

If an $osmfile is provided, the contained [osm] relations will also be
used to create the hierarchy.

=cut

sub postprocess_stops
{
	my ( $self, $osmfile ) = @_;

	if ($osmfile) {
		$self->load_osm($osmfile);
	}

	foreach my $stop ( values %{ $self->{STOPS}->{stops} } ) {
		if ( scalar keys %{ $stop->{modes} } == 1 ) {
			given ( ( keys %{ $stop->{modes} } )[0] ) {
				when ("tram") {
					$stop->{type} = 'tram_stop';
				}
				when ("bus") {
					$stop->{type} = 'bus_stop';
				}
			}
		}
		delete $stop->{modes};
	}
	foreach my $p ( values %{ $self->{STOPS}->{areas} } ) {

		my $n = scalar @{ $p->{members} };
		$p->{geom} = [ 0, 0 ];
		$p->{geom}->[0] += $_->{geom}[0]
			for ( map { $self->{STOPS}->{stops}->{$_} } @{ $p->{members} } );
		$p->{geom}->[1] += $_->{geom}[1]
			for ( map { $self->{STOPS}->{stops}->{$_} } @{ $p->{members} } );
		$p->{geom} = [ map { $_ / $n } @{ $p->{geom} } ];
	}
	foreach my $p ( values %{ $self->{STOPS}->{interchanges} } ) {

		my $n = scalar @{ $p->{members} };
		$p->{geom} = [ 0, 0 ];
		$p->{geom}->[0] += $_->{geom}[0]
			for ( map { $self->{STOPS}->{areas}->{$_} } @{ $p->{members} } );
		$p->{geom}->[1] += $_->{geom}[1]
			for ( map { $self->{STOPS}->{areas}->{$_} } @{ $p->{members} } );
		$p->{geom} = [ map { $_ / $n } @{ $p->{geom} } ];
	}

	foreach (
		values %{ $self->{STOPS}->{stops} },
		values %{ $self->{STOPS}->{areas} },
		values %{ $self->{STOPS}->{interchanges} }
		)
	{
		local $ENV{LC_CTYPE} = 'hu_HU.UTF-8';
		{
			use locale;

			$_->{names} = [ sort keys %{ $_->{names} } ];
		}
	}

	{
		my $stops = IO::File->new( File::Spec->catfile( $self->{dir}, 'stops.yml' ), 'w' );
		$stops->binmode(':utf8');
		$stops->print( YAML::Dump $self->{STOPS} );
		undef $stops;
	}
}

sub rat_name
{
	my $name = shift;
	$name =~ s/ (?:M\+H|M H|M|H)$//g;
	$name;
}

=head2 postprocess_shapes

=cut

sub postprocess_shapes
{
}

1;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
