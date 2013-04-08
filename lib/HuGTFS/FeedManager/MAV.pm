
=head1 NAME

HuGTFS::FeedManager::MAV - HuGTFS feed manager for downloading + parsing MÁV-START timetables.

=head1 SYNOPSIS

	use HuGTFS::FeedManager::MAV;

=head1 DESCRIPTION

=head1 METHODS

=cut

package HuGTFS::FeedManager::MAV;

use 5.14.0;
use utf8;
use strict;
use warnings;

use DateTime;
use File::Spec;
use Carp qw/ cluck confess croak /;
use WWW::Mechanize;
use Data::Dumper;
use File::Spec::Functions qw/catfile catdir/;
use DBI;
use Text::CSV::Encoded;
use Text::Unidecode;
use Digest::JHash qw(jhash);

use JSON qw/decode_json/;

use HuGTFS::Cal;
use HuGTFS::Util qw(:utils);
use HuGTFS::Dumper;

use Mouse;

with 'HuGTFS::FeedManager';
__PACKAGE__->meta->make_immutable;

has 'ignore_non_hungarian' => (
	is      => 'rw',
	isa     => 'Bool',
	default => 1,
);

has 'selective' => (
	is      => 'rw',
	isa     => 'Str',
	default => 'trip_*.html',
);

no Mouse;

### DATEMOD: Change to reflect the current 'timetable year'
use constant {
	CAL_START         => HuGTFS::Cal::CAL_START,
	CAL_END           => HuGTFS::Cal::CAL_END,
};

my $log = Log::Log4perl->get_logger(__PACKAGE__);

my $OPERATOR = qr/\b(?:MÁV|GySEV)\b/i;

my ( $PLATFORMS, $PLATFORM_NODE ) = ( {}, {} );
my ($AGENCY) = (
	{
		'agency_phone'    => '+36 (1) 371 94 49',
		'agency_lang'     => 'hu',
		'agency_id'       => 'MAVSTART',
		'agency_name'     => 'MÁV-START Zrt.',
		'agency_url'      => 'http://www.mav-start.hu',
		'agency_timezone' => 'Europe/Budapest',
		'routes'          => [
			{
				'route_type'       => 'rail',
				'route_id'         => 'NEMZETKOZI-GYORS',
				'route_long_name'  => 'nemzetközi gyorsvonat',
				#'route_short_name' => 'NGY'
			},
			{
				'route_type'       => 'rail',
				'route_id'         => 'NEMZETKOZI-SZEMELY',
				'route_long_name'  => 'nemzetközi személyvonat',
				#'route_short_name' => 'NSZ'
			},
			{
				'route_type'       => 'rail',
				'route_id'         => 'BELFOLDI-EXPRESSZ',
				'route_long_name'  => 'belföldi expresszvonat',
				#'route_short_name' => 'E'
			},
			{
				'route_type'       => 'rail',
				'route_id'         => 'BELFOLDI-GYORS',
				'route_long_name'  => 'belföldi gyorsvonat',
				'route_short_name' => 'GY'
			},
			{
				'route_type'       => 'rail',
				'route_id'         => 'EUREGIO',
				'route_long_name'  => 'EUREGIO',
				#'route_short_name' => 'EUR'
			},
			{
				'route_type'       => 'rail',
				'route_id'         => 'EUROCITY',
				'route_long_name'  => 'EuroCity',
				'route_short_name' => 'EC'
			},
			{
				'route_type'       => 'rail',
				'route_id'         => 'EURONIGHT',
				'route_long_name'  => 'EuroNight',
				'route_short_name' => 'EN'
			},
			{
				'route_type'       => 'rail',
				'route_id'         => 'INTERCITY',
				'route_long_name'  => 'InterCity',
				'route_short_name' => 'IC'
			},
			{
				'route_type'       => 'rail',
				'route_id'         => 'INTERREGIO',
				'route_long_name'  => 'InterRégió',
				'route_short_name' => 'IR'
			},
			{
				'route_type'       => 'rail',
				'route_id'         => 'RAILJET',
				'route_long_name'  => 'railjet',
				'route_short_name' => 'RJ'
			},
			{
				'route_type'       => 'rail',
				'route_id'         => 'SEBES',
				'route_long_name'  => 'sebesvonat',
				'route_short_name' => 'S'
			},
			{
				'route_type'       => 'rail',
				'route_id'         => 'SZEMELY',
				'route_long_name'  => 'személyvonat',
				'route_short_name' => 'SZ'
			},
			{
				'route_type'       => 'bus',
				'route_id'         => 'ICVONATPOTLO',
				'route_long_name'  => 'InterCity pótló busz',
				'route_short_name' => 'ICvp'
			},
			{
				'route_type'       => 'bus',
				'route_id'         => 'VONATPOTLO',
				'route_long_name'  => 'vonatpótló autóbusz',
				'route_short_name' => 'VP'
			},

			{
				'route_type'       => 'rail',
				'route_id'         => 'REGIONALIS',
				'route_long_name'  => 'Regionalis vonat',
				#'route_short_name' => 'R'
			},
			{
				'route_type'       => 'rail',
				'route_id'         => 'EXPRESSZ',
				'route_long_name'  => 'Expressz',
				'route_short_name' => 'Ex'
			},
			{
				'route_type'       => 'rail',
				'route_id'         => 'KULONVONAT',
				'route_long_name'  => 'különvonat',
				#'route_short_name' => 'K'
			},
			{
				'route_type'       => 'rail',
				'route_id'         => 'POSTAVONAT',
				'route_long_name'  => 'postavonat',
				#'route_short_name' => 'pv'
			},
			{
				'route_type'       => 'rail',
				'route_id'         => 'S-BAHN',
				'route_long_name'  => 'S-Bahn',
				#'route_short_name' => ''
			},
		],
	}
);
my ($routes)
	= { map { ( $_->{route_long_name} || $_->{route_short_name} ) => $_ }
		@{ $AGENCY->{routes} } };
my ( $STOPS, $TRIPS, $STOP_TYPE, $STOP_CODE, $SERVICE_MAP, $PARSED_SERVICE_MAP, $STOP_MAP,
	%R_MONTH )
	= ( {}, [], {}, {}, {}, {}, {}, () );

$STOP_MAP = {
#<<<
	# ELVIRA => VPE
	# this maps the ELVIRA name to the VPE one

	'Angyalföld'                => 'Budapest-Angyalföld',
	'Bánhalma Halastó'          => 'Bánhalma-Halastó',
	'Bélapátfalvi Cementgyár'   => 'Bélapátfalvai Cementgyár',
	'Csikóstőttős'              => 'Csikóstöttös',
	'Hódmezővásárhelyi Népkert' => 'Hódmezővásárhely-Népkert',
	'Gödöllő Állami telepek'    => 'Gödöllő-Állami telepek',
	'Központi Főmajor'          => 'Központi főmajor',
	'Lengyeltóti (Buzsák)'      => 'Lengyeltóti',

	'Beli Manastir'             => 'Beli Manastír',
	'Hodos'                     => 'Hodoš',
	'Horgos'                    => 'Horgoš',
};

my $ELVIRA;
BEGIN {
	$ELVIRA = 'http://elvira.mav-start.hu/elvira.dll';
};



my $TIMEZONE = 'Europe/Budapest';
my $BORDER_STATIONS = {
	# ELVIRA name
	#'Beli Manastir' => { timezone => 'Europe/Zagreb', },
	#'Curtici'       => { timezone => 'Europe/Bucharest', },
	#'Drnje'         => { timezone => 'Europe/Zagreb', },
	#'Hodos'         => { timezone => 'Europe/Ljubljana', },
	#'Horgos'        => { timezone => 'Europe/Belgrade', },
	#'Koprivnica'    => { timezone => 'Europe/Zagreb', },
	#'Salonta'       => { timezone => 'Europe/Bucharest', },
	#'Subotica'      => { timezone => 'Europe/Belgrade', },
	#'Oradea'        => { timezone => 'Europe/Bucharest', },
};

my $BB_STOPS = {
	map { $_ => 1 }
	'Óbuda',                 'Üröm',
	'Aquincum felső',        'Budapest-Déli',
	'Kelenföld',             'Albertfalva',
	'Budafok',               'Háros',
	'Budatétény',            'Barosstelep',
	'Nagytétény-Diósd',      'Tétényliget',
	'Nagytétény',            'Soroksár',
	'Pesterzsébet',          'Soroksári út',
	'Ferencváros',           'Budapest-Keleti',
	'Pestszentimre',         'Pestszentimre felső',
	'Kispest',               'Kőbánya-Kispest',
	'Kőbánya alsó',          'Pestszenlőrinc',
	'Szemeretelep',          'Ferihegy',
	'Kőbánya felső',         'Rákos',
	'Rákosliget',            'Rákoscsaba-Újetelep',
	'Rákoscsaba',            'Rákoshegy',
	'Rákoskert',             'Zugló',
	'Rákosrendező',          'Budapest-Nyugati',
	'Istvántelek',           'Rákospalota-Újpest',
	'Rákospalota-Kertváros', 'Angyalföld',
	'Újpest',                'Vasútmúzeum'
};

my $BB_BORDER_STOPS = {
	map { $_ => 1 }
	'Esztergom',             'Hatvan',
	'Jászfényszaru',         'Kunszentmiklós-Tass',
	'Lajosmizse',            'Nagykőrös',
	'Nógrádkövesd',          'Pusztaszabolcs',
	'Székesfehérvár',        'Szob',
	'Szokolya',              'Szolnok',
	'Tatabánya',
};
#>>>

=head2 download %options

Downloads trip & station timetables from ELVIRA.

By default, only trip timetables are downloaded. Stations may be downloaded by passing
a C<stations => 1> parameter. Downloading trips may be skipped with a C<trips => 0> parameter.

Data is only downloaded if C<force> is true, or the the database version is different
from the already downloaded version.

=cut

sub download
{
	use bignum;

	my $self   = shift;
	my %params = @_;
	my ( $trips, $stations ) = ( 1, 0 );

	$trips    = $params{trips}    if defined $params{trips};
	$stations = $params{stations} if defined $params{stations};

	my $mech = WWW::Mechanize->new( agent => 'MASTER' );
	$mech->get($ELVIRA);

	my $content = $mech->content;

	my (@date) = ( $content =~ m{<a href="mk">(\d{4})\.(\d{2})\.(\d{2}) (\d{2}):(\d{2})</a>} );

	my ($version) = ( $content =~ m{<span class="verzio">\s*(.*?)\s*</span>}s );

	$version =~ s/<a href="mk">|<\/a>//g;
	$version =~ s/\s+/ /gm;

	my $updated = DateTime->new(
		year      => $date[0],
		month     => $date[1],
		day       => $date[2],
		hour      => $date[3],
		minute    => $date[4],
		time_zone => 'Europe/Budapest',
	);

	my $oldest;
	my $oldtime = 99999999999999;
	for ( glob catfile( $self->data_directory, '*.html' ) ) {
		my $thistime = (stat)[9];
		if ( $thistime < $oldtime ) {
			( $oldest, $oldtime ) = ( $_, $thistime );
		}
	}
	$oldtime = 0 if $oldtime == 99999999999999;
	my $downloaded = DateTime->from_epoch( epoch => $oldtime );

	if ( $self->force || $downloaded < $updated ) {
		$log->info("Updated timetable available: $version (last downloaded at $downloaded)");

		unlink glob catfile( $self->data_directory, '*.html' );
	}
	else {
		$log->debug("No newer version available.");
		return 0;
	}

	use constant {
		VPE_STOP_CODES => 'http://www.vpe.hu/takt/szh_lista.php?id_id=10000005',    # DATEMOD
		MAVSTART_MODIFICATIONS_URL =>
			"$ELVIRA/xslvzs/mk?language=1",
		MAVSTART_TRIPS_URL =>
			"$ELVIRA/xslvzs/vt?mind=1&language=1&ed=*ED*&v=",
		MAVSTART_STATIONS_URL =>
			"$ELVIRA/xslvzs/af?mind=1&language=1&ed=*ED*&i=",
		MAVSTART_LOCAL_TRANSPORT_URL =>
			"$ELVIRA/xslvzs/hk?hk=1&language=1&ed=*ED*",
		MAVSTART_STATIONS_REGEX =>
			qr|^http://elvira\.mav-start\.hu/elvira\.dll/xslvzs/af\?i=(\d+)|,
	};

	my ( $vpe_html, $local_html, $mod_html ) = (
		catfile( $self->data_directory, 'vpe.html' ),
		catfile( $self->data_directory, 'local_transport.html' ),
		catfile( $self->data_directory, 'modifications.html' ),
	);

	my $TRIP_NUM    = 1;
	my $STATION_NUM = 1;
	our $ED = '';

	mkdir( $self->data_directory ) unless -d $self->data_directory;

	sub url($)
	{
		local $_ = shift;
		s/\*ED\*/$ED/g;
		$_;
	}

	$log->info("VPE stop codes...");
	$mech->get( VPE_STOP_CODES, 'Accept-Encoding' => 'identity', ':content_file' => $vpe_html )
		unless -f $vpe_html;

	$log->info("MAVSTART modifications...");
	$mech->get( MAVSTART_MODIFICATIONS_URL, ':content_file' => $mod_html )
		unless -f $mod_html;

	{
		open( my $f, '<', $mod_html );

		while (<$f>) {
			if (m/ed:'([A-F0-9]+)'/) {
				$ED = $1;
				last;
			}
		}
		$log->error("NEED ED") unless $ED;

		close($f);
	}

	$log->info("MAVSTART local transport...");
	$mech->get( url MAVSTART_LOCAL_TRANSPORT_URL, ':content_file' => $local_html )
		unless -f $local_html;

	local $| = 1;

	if ($trips) {
		$log->info("MAVSTART trips... {takes a long time}");

		while ($trips) {
			$TRIP_NUM++ && next
				if -f catfile( $self->data_directory, "trip_$TRIP_NUM.html" );

			$log->debug($TRIP_NUM);

			eval { $mech->get( url MAVSTART_TRIPS_URL . $TRIP_NUM ) };
			redo if $@;

			# no more routes
			last unless $mech->content =~ m/id="kozlekedik"/;

			### "ELVIRA v02.18 (d)" ought to get murdered...
			#redo if $mech->content =~ m/ELVIRA v\d+\.\d+ \(d\)/i;

			#write to data file
			open my $r, "> :utf8", catfile( $self->data_directory, "trip_$TRIP_NUM.html" )
				or die $!;
			print $r localize( $mech->content );
			close $r;

			$TRIP_NUM++;
		}
	}

	if ($stations) {
		$log->info("MAVSTART stations...");
		while ($stations) {
			$STATION_NUM++ && next
				if -f catfile( $self->data_directory, "station_$STATION_NUM.html" );

			$log->debug($STATION_NUM);

			eval { $mech->get( url MAVSTART_STATIONS_URL . $STATION_NUM ) };
			redo if $@;

			# no more stations
			last unless $mech->content =~ m/h2 align="center"/;

			### "ELVIRA v02.18 (d)" ought to get murdered...
			redo if $mech->content =~ m/ELVIRA v\d+\.\d+ \(d\)/i;

			#write to data file
			open my $r, "> :utf8",
				catfile( $self->data_directory, "station_$STATION_NUM.html" );
			print $r localize( $mech->content );
			close $r;

			$STATION_NUM++;
		}
	}

	return 1;
}

=head3 localize

Localizes links, changes the charset to utf-8.

=cut

sub localize
{
	my $page = shift;
	$page =~ s/iso-8859-2/utf-8/g;
	$page =~ s/"af\?i=(\d+).*?"/"station_$1.html"/g;
	$page =~ s/"vt\?v=(\d+).*?"/"trip_$1.html"/g;
	$page =~ s/"mk"/"modifications.html"/g;
	$page =~ s/"hk?id=\d+?"/"local_transport.html"/g;
	$page =~ s/<base .*?>//g;
	$page =~ s!<script.*?</script>!!g;

	return $page;
}

=head2 parse %options

Parses trip timetables, creates stops & shapes.

Shapes are created using available railway data within OSM, which requires the the OSM
railway stations/halts be situated on the actual railway way.

B<IF> both OSM and ELVIRA contains platform data than GTFS parent_stations & stops are
created.

=head2 options

=over 3

=item stops

Process stops, loading geometry data from OSM.

=item shapes

Process trips, creating shapes where possible.

=item trips

Process trips from the HTML data.

=item selective

=back

=cut

sub run_interval($$);

sub parse
{
	my $self   = shift;
	my %params = @_;

	my ( $process_stops, $process_shapes, $process_trips, $caltest, ) = ( 1, 1, 1, '' );

	if ( $self->automatic ) {
		( $process_stops, $process_shapes, $process_trips ) = ( 1, 1, 1 );
	}

	if ( defined $params{stops} ) {
		$process_stops = $params{stops};
	}
	if ( defined $params{shapes} ) {
		$process_shapes = $params{shapes};
	}
	if ( defined $params{trips} ) {
		$process_trips = $params{trips};
	}
	if ( defined $params{caltest} ) {
		$caltest = $params{caltest};
	}
	if ( defined $params{ignore_non_hungarian} ) {
		$self->ignore_non_hungarian( $params{ignore_non_hungarian} );
	}
	if ( $params{selective} ) {
		$self->selective( $params{selective} );
	}

	if ($caltest) {
		init_cal();

		my $service_id = create_service_from_text($caltest);
		if($service_id) {
			print "\n$caltest\n";
			HuGTFS::Cal->find($service_id)->PRINT;
		} else {
			print "$caltest\n\tFailed to parse\n";
		}
		return 0;
	}

	if ($process_trips) {
		eval '
		use Text::CSV::Encoded;
		use XML::Twig;
		use DateTime;
	';

		$self->process_trips();
	}

	my $dumper = HuGTFS::Dumper->new( dir => catdir( $self->directory, 'gtfs' ) );
	$dumper->clean_dir;

	if ( $process_stops || $process_shapes ) {

		my $SHAPE_NODES = {};

		if ($process_stops) {

			sub sanify($)
			{
				local $_ = shift;
				s/^Gara //g;
				$_;
			}

			my ( $osm_railway, $osm_relations, $DEFAULT_PLATFORM, $STATION_ENTITY );
			my ( $stop_positionify ) = {},

			my $pr;
			$pr = sub {
				my $e = shift;
				if (   $e->isa("Geo::OSM::Relation")
					&& $e->tag("public_transport")
					&& $e->tag("public_transport")
					=~ m/^(?:railway_station|railway_halt|stops|stop_area)$/
					&& $e->tag("operator")
					&& $e->tag('operator') =~ $OPERATOR )
				{
					$osm_relations->{masters}->{ $e->id } = $e;
				}
				elsif ($e->isa("Geo::OSM::Relation")
					&& $e->tag("public_transport")
					&& $e->tag("public_transport") eq 'stop'
					&& $e->tag("operator")
					&& $e->tag('operator') =~ $OPERATOR )
				{
					$osm_relations->{stops}->{ $e->id } = $e;
				}
				elsif ($e->isa("Geo::OSM::Node")
					&& $e->tag("public_transport")
					&& $e->tag("public_transport") eq 'stop_position' )
				{
					$osm_relations->{node}->{ $e->id } = $e;
				}
				# Make sure the stop_position can't be used as a "plain" station
				elsif ($e->isa("Geo::OSM::Relation")
					&& $e->tag("public_transport")
					&& $e->tag("public_transport") eq 'stop')
				{
					foreach my $m ( $e->members ) {
						next unless $m->role && $m->role eq 'stop' && $m->member_type eq 'node';
						$stop_positionify->{ $m->ref } = 1;
					}
				}

				if ($e->isa("Geo::OSM::Node")
					&& $e->tag('name')
					&& ( !$e->tag('operator') || $e->tag('operator') =~ $OPERATOR )
					&& $e->tag('railway')
					&& $e->tag('railway') =~ m/^(?:halt|station)$/ )
				{

					my $name = sanify $e->tag('name');
					$osm_relations->{node}->{ $e->id } = $e;

					return # Keep the first station when there are multiple places with the same name
						if $osm_railway->{ sanify $e->tag('name') }
							&& $osm_railway->{ sanify $e->tag('name') }->tag('railway') eq
							'station';

					$e->set_tag( 'entity', entity_id($e) );

					$osm_railway->{ sanify $e->tag('name') }     = $e;
					$osm_railway->{ sanify $e->tag('old_name') } = $e
						if $e->tag('old_name')
							&& !$osm_railway->{ sanify $e->tag('old_name') };
					$osm_railway->{ sanify $e->tag('alt_name') } = $e
						if $e->tag('alt_name')
							&& !$osm_railway->{ sanify $e->tag('alt_name') };
					$osm_railway->{ sanify $e->tag('name:hu') } = $e
						if $e->tag('name:hu')
							&& !$osm_railway->{ sanify $e->tag('name:hu') };
					$osm_railway->{ unidecode( sanify $e->tag('name') ) } = $e
						if $e->tag('name')
							&& !$osm_railway->{ unidecode( sanify $e->tag('name') ) };
					$osm_railway->{ sanify $e->tag('ascii_name') } = $e
						if $e->tag('ascii_name')
							&& !$osm_railway->{ sanify $e->tag('ascii_name') };

					# XXX Use ELVIRA -> VA map too

					# XXX Case sensitivity
				}
			};

			$log->info("Loading osm (stops)...");
			unless ( Geo::OSM::OsmReader->init($pr)->load( $self->osm_file ) ) {

				$log->logdie( "Failed to parse osm file: " . $self->osm_file );
			}

			for(values %$stop_positionify) {
				my $node = $osm_relations->{node}->{ $_ };
				$node->tag("railway", "nonrailway") if $node;
			}

			$log->info("...done");

			# Process site relations
			foreach my $master ( values %{ $osm_relations->{masters} } ) {
				my $name = sanify $master->tag('name');

				if($master->tag("public_transport") =~ m/^(?:stops|stop_area)$/) {
					$name = undef;

					foreach my $m ( $master->members ) {
						next if $m->role && $m->role eq 'station';

						if ( $m->member_type eq 'relation' ) {
							my $r = $osm_relations->{stops}->{ $m->ref };
							if ($r && (!$r->tag("operator") || $r->tag("operator") =~ $OPERATOR)) {
								$name = sanify $r->tag('name');
							}
						}
						elsif ( $m->member_type eq 'node' ) {
							my $node = $osm_relations->{node}->{ $m->ref };
							if ($node && $node->tag('ref') && (!$node->tag("operator") || $node->tag("operator") =~ $OPERATOR)) {
								$name = sanify $node->tag('name');
							}
						}
					}
				}

				$STATION_ENTITY->{$name} = entity_id($master);

				foreach my $m ( $master->members ) {
					next if $m->role && $m->role eq 'station';

					if ( $m->member_type eq 'relation' ) {
						my $r = $osm_relations->{stops}->{ $m->ref };
						if ($r && (!$r->tag("operator") || $r->tag("operator") =~ $OPERATOR)) {
							$r->set_tag( "hugtfs", "visited" );

							my $node;
							foreach my $rm ( $r->members ) {
								if ( $rm->role && $rm->role eq 'stop' ) {
									$node = $osm_relations->{node}->{ $rm->ref };
									last if $node;
								}
							}
							if ( $node && $r->tag('ref') ) {
								$node->set_tag( 'name',   $r->tag('name') );
								$node->set_tag( 'entity', entity_id($r) );
								$osm_railway->{ 'ST-' . $name . '-' . $r->tag('ref') } = $node;

								# Used when there is no platform specified, to avoid using the location_type=1 for stop_times
								if ( !$osm_railway->{ 'ST-' . $name } ) {
									$DEFAULT_PLATFORM->{$name} = $r->tag("ref");
									$osm_railway->{ 'ST-' . $name } = $node;
								}
							}

							# Allow upto one ref-less platform
							# 	This assumes that the station/halt doesn't have more than one platform
							# 	so giving it a ref would be useless
							elsif ( $node && !$osm_railway->{ 'ST-' . $name } ) {
								$DEFAULT_PLATFORM->{$name} = '';
								$node->set_tag( 'name',   $r->tag('name') );
								$node->set_tag( 'entity', entity_id($r) );
								$osm_railway->{ 'ST-' . $name } = $node;
							}
							else {
								$log->warn( "Relation "
										. $master->id
										. ": failed to process member "
										. $m->ref );
							}
						}
						else {

							#$log->warn(
							#	"Relation " . $master->id . ": missing member " . $m->ref );
						}
					}
					elsif ( $m->member_type eq 'node' ) {
						my $node = $osm_relations->{node}->{ $m->ref };
						if ($node && $node->tag('ref') && (!$node->tag("operator") || $node->tag("operator") =~ $OPERATOR)) {
							$node->set_tag( 'entity', entity_id($node) );
							$osm_railway->{ 'ST-' . $name . '-' . $node->tag('ref') } = $node;
						}
						else {
							#$log->warn(
							#	"Relation " . $master->id . ": missing member " . $m->ref );
						}
					}
					else {
						$log->warn( "Relation " . $master->id . ": ignored member " . $m->ref );
					}
				}
			}

			### XXX XXX
			foreach my $stop ( values %$STOPS ) {
				my ( @cord, $node_id );
				my $name = $stop->{stop_name};

				# Use a ref-less platform, otherwise a "normal" node
				my $node = $osm_railway->{ 'ST-' . $name } || $osm_railway->{$name};

				if ( !$node && $name =~ m/(.*) an der (.*)/ ) {
					$node = $osm_railway->{"$1/$2"};
				}

				if ($node) {
					@cord = ( $node->lat, $node->lon );

					$SHAPE_NODES->{ $node->id } = $node;

					$stop->{stop_osm_entity} = $node->tag("entity") || entity_id($node);

					$PLATFORM_NODE->{ $stop->{stop_osm_entity} } = $node->id
						if $node->tag("entity");
				}

				unless (@cord) {
					if ( $STOP_CODE->{$name} || $BORDER_STATIONS->{$name} ) {
						$log->warn("Geodata [HU  MISSING]: $name");
					}
					else {
						$log->warn("Geodata [INT MISSING]: $name");
					}
					@cord = ( 45, 21 );
				}

				@{$stop}{ 'stop_lat', 'stop_lon' } = @cord;
			}

			$log->info("Performing trip<->platform pairing...");

			my $warned = {};
			foreach my $trip (@$TRIPS) {
				foreach my $st ( @{ $trip->{stop_times} } ) {

					my $stop_name = $STOPS->{ $st->{stop_id} }->{stop_name};
					if ( $PLATFORMS->{$stop_name} ) {
						my ($ts) = ( $trip->{trip_short_name} =~ m/(\d+)/ );

						if ( $PLATFORMS->{$stop_name}->{ $trip->{trip_short_name} } ) {
							my $p = $PLATFORMS->{$stop_name}->{ $trip->{trip_short_name} };
							($p) = ( split /-/, $p );

							my $stop_id = $st->{stop_id} . "_P$p";
							my $node    = $osm_railway->{ 'ST-' . $stop_name . "-$p" };

							if ($node) {
								if ( !$STOPS->{$stop_id} ) {
									$STOPS->{ $st->{stop_id} }->{location_type} = 1;
									$STOPS->{ $st->{stop_id} }->{stop_lat}
										= $STOPS->{ $st->{stop_id} }->{stop_lon} = 0;

									$STOPS->{$stop_id} = {
										%{ $STOPS->{ $st->{stop_id} } },
										stop_osm_entity => $node->tag('entity'),
										stop_lat        => $node->lat,
										stop_lon        => $node->lon,
										stop_name       => $node->tag('name'),
										stop_id         => $stop_id,
										location_type   => 0,
										parent_station  => $st->{stop_id}
									};
								}
								$st->{stop_id} = $stop_id;

								$SHAPE_NODES->{ $node->id } = $node;
								$PLATFORM_NODE->{ $node->tag('entity') } = $node->id;

								next;
							}
							else {
								unless ( $warned->{ $stop_name . '_P' . $p } ) {
									$log->warn("Station '$stop_name' is missing platform $p");
									$warned->{ $stop_name . '_P' . $p } = 1;
								}
							}
						}

						my $node = $osm_railway->{ 'ST-' . $stop_name };
						next unless $node;

						my $stop_id = $st->{stop_id} . "_P" . $DEFAULT_PLATFORM->{$stop_name};

						if ( !$STOPS->{$stop_id} ) {
							$STOPS->{ $st->{stop_id} }->{location_type} = 1;
							$STOPS->{ $st->{stop_id} }->{stop_lat}
								= $STOPS->{ $st->{stop_id} }->{stop_lon} = 0;

							$STOPS->{$stop_id} = {
								%{ $STOPS->{ $st->{stop_id} } },
								stop_osm_entity => $node->tag('entity'),
								stop_lat        => $node->lat,
								stop_lon        => $node->lon,
								stop_name       => $node->tag('name'),
								stop_id         => $stop_id,
								location_type   => 0,
								parent_station  => $st->{stop_id}
							};

							$SHAPE_NODES->{ $node->id } = $node;
							$PLATFORM_NODE->{ $node->tag('entity') } = $node->id;
						}
						$st->{stop_id} = $stop_id;
					}
				}
			}

			# Average coords for GTFS "stations" using platforms
			my $stop_count = {};
			foreach my $stop ( values %$STOPS ) {
				if ( $stop->{location_type} && $stop->{location_type} == 1 ) {
					$stop->{stop_osm_entity} = $STATION_ENTITY->{ $stop->{stop_name} };
					next;
				}
				next unless $stop->{parent_station};

				$stop_count->{ $stop->{parent_station} }++;

				$STOPS->{ $stop->{parent_station} }->{stop_lat} += $stop->{stop_lat};
				$STOPS->{ $stop->{parent_station} }->{stop_lon} += $stop->{stop_lon};
			}
			for ( keys %$stop_count ) {
				$STOPS->{$_}->{stop_lat} /= $stop_count->{$_};
				$STOPS->{$_}->{stop_lon} /= $stop_count->{$_};
			}
		}

		if ($process_shapes) {
			my $mech = WWW::Mechanize->new();
			my $SP_CACHE = {};

			$TRIPS = [ sort { $a->{trip_id} cmp $b->{trip_id} } @$TRIPS ];
			while ( my $trip = shift @$TRIPS ) {
				### Lets try obtaining a shape for each trip, in a worst-case
				### scenario, the stops will get connected...

				my $shape_id = "SHAPE_" . $trip->{trip_id};
				my $vp = $trip->{route_id} =~ m/VONATPOTLO/;

				my ( $prev_stop, @path ) = ( undef, () );
				foreach my $stop_time ( @{ $trip->{stop_times} } ) {
					my $stop = { %{ $STOPS->{ $stop_time->{stop_id} } }, %$stop_time };

					if ($prev_stop) {
						my @shortest = ();

						my $url = 'http://localhost:5001/viaroute?output=json&instructions=false&compression=false';

						for ( $prev_stop, $stop ) {
							if ($url  && $_->{stop_osm_entity} && $PLATFORM_NODE->{ $_->{stop_osm_entity} }) {
								my $node = $SHAPE_NODES
									->{ $PLATFORM_NODE->{ $_->{stop_osm_entity} } };
								if ( !$node ) {
									$url = undef;
								}
								else {
									$url .= '&loc=' . $node->lat . ',' . $node->lon;
								}
							}
						}

						if ( !$vp && $url && exists $SP_CACHE->{$url} ) {
							@shortest = @{ $SP_CACHE->{$url} };
						}
						elsif ($url && !$vp) {
							$SP_CACHE->{$url} = [];
							eval { $mech->get($url); };
							unless ($@) {
								my $json = eval { decode_json( $mech->content ) };
								if ($@) {
									$log->fatal("JSON Decode error: $@");
									$log->fatal(
										"Failed to find shape ($trip->{trip_id}, $prev_stop->{stop_name} -> $stop->{stop_name}):"
											. "$json->{status_message}\n\t$url" );

									$json = { status => '1' };
								}

								if ( $json->{status} eq '0' ) {

									my $d1 = $stop->{shape_dist_traveled} - $prev_stop->{shape_dist_traveled};
									my $d2 = $json->{route_summary}{total_distance} / 1000;

									if(($d1 < 1.2 * $d2 && $d1 > 0.8 * $d2) || abs($d1 - $d2) < 3) {

										@shortest = @{ $json->{route_geometry} };
										shift @shortest;

										$SP_CACHE->{$url} = \@shortest;
									} else {

										$log->warn( "Bad length trip ($trip->{trip_id}):"
												. " $prev_stop->{stop_name} -> $stop->{stop_name} $d1 km, found $d2 km"
										);
									}
								} else {
									$log->fatal(
										"Failed to find shape ($trip->{trip_id}): $json->{status_message}\n\t$url"
									);
								}
							} else {
								$log->fatal(
									"Failed to find shape ($trip->{trip_id}): $@"
								);
							}
						}

						unless (@shortest) {
							push @path,
								[
								@{$stop}{ 'stop_lat', 'stop_lon' },
								$stop->{shape_dist_traveled},
								];
						}
						else {
							my $j = 0;
							push @path, map {
								[
									@$_, $prev_stop->{shape_dist_traveled} + ( ++$j / 10000 ),
								]
							} @shortest;

							$path[$#path]->[2] = $stop->{shape_dist_traveled};
						}
					}
					else {
						my $node
							= $SHAPE_NODES->{ $PLATFORM_NODE->{ $stop->{stop_osm_entity} } };
						@path = ( [ $node->lat, $node->lon, $stop->{shape_dist_traveled}, ] );
					}

					$prev_stop = $stop;
				}

				$trip->{shape} = {
					shape_id     => $shape_id,
					shape_points => [
						map {
							{
								shape_pt_lat        => $_->[0],
								shape_pt_lon        => $_->[1],
								shape_dist_traveled => $_->[2],
							}
							} @path
					],
				};

				$dumper->dump_trip($trip);
			}
		}
	}

	if ( !$process_shapes ) {
		foreach (@$TRIPS) {
			$dumper->dump_trip($_);
		}
	}

	$dumper->dump_agency($AGENCY);
	$dumper->dump_calendar($_) for ( HuGTFS::Cal->dump );
	$dumper->dump_stop($_) for ( map { $STOPS->{$_} } sort keys %$STOPS );

	$dumper->deinit_dumper();

	# Reset defaults
	( $PLATFORMS, $PLATFORM_NODE ) = ( {}, {} );
	( $STOPS, $TRIPS, $STOP_CODE, $STOP_TYPE, $SERVICE_MAP, $PARSED_SERVICE_MAP, )
		= ( {}, [], {}, {}, {}, {}, {}, () );
}

sub process_trips
{
	our $self = shift;

	init_cal();

	{
		$log->info("Processing vpe data...");

		my $vpe_twig = XML::Twig->new(
			discard_spaces => 1,
			twig_roots     => { 'tr' => 1, }
		);

		$vpe_twig->parse_html( slurp catfile( $self->data_directory, 'vpe.html' ) );

		foreach my $stop ( $vpe_twig->get_xpath('tr') ) {
			my @fields = qw/agency name type t_code code cat1 cat2/;
			my $stop = { map { ( shift @fields ) => $_->text } $stop->get_xpath('td') };

			next unless $stop->{code} && $stop->{code} =~ m/^55/;

			$stop->{name} =~ s/ (?:mh\.?|mrh\.|pu\.|mh\. ipvk\.?|ipvk\.|ipv\.|mh\. elág\.)$//;

			$STOP_TYPE->{ $stop->{name} }
				= ( $stop->{type} =~ m/állomás/ ) ? 'station' : 'stop';

			#$stop->{code} =~ s/^55/M/g;

			$STOP_CODE->{ $stop->{name} } = $stop->{code};
		}

		while ( my ( $elvira, $vpe ) = each %$STOP_MAP ) {
			$STOP_CODE->{$elvira} = $STOP_CODE->{$vpe};
			$STOP_TYPE->{$elvira} = $STOP_TYPE->{$vpe};

			$BORDER_STATIONS->{$vpe} = $BORDER_STATIONS->{$elvira}
				if $BORDER_STATIONS->{$elvira};
		}
	}

	{
		$log->info("Processing trips...");

		my $twig = XML::Twig->new(
			discard_spaces => 1,
			twig_roots     => {
				'div[@id="menetrend"]/table/tbody/tr[@class="l"]/td/a' => \&handler_stop,
				'div[@id="menetrend"]'                                 => 1,
				'div[@id="tul"]'                                       => 1,
				'div[@id="kozlekedik"]'                                => 1,
				'div[@id="szolgaltatasok"]'                            => 1,
				'div[@id="valtozat"]'                                  => 1,
			}
		);

		my $q = 0;
		foreach my $trip (
			reverse
			sort { ( $a =~ m/(\d+)/ )[0] <=> ( $b =~ m/(\d+)/ )[0] }
			glob( catfile( $self->data_directory, $self->selective ) )
			)
		{

			#next if $ARGV[1] && $trip !~ m/$ARGV[1]/;
			#undef $ARGV[1] if ( $ARGV[1] && !$ARGV[3] );

			my ( $elvira_trip_id, $stops, $variation_intervals ) = ( ( $trip =~ m/(\d+)/ )[0] );

			$log->debug("Processing $elvira_trip_id");

			eval {
				$twig->parse_html( slurp $trip);

				### [ service_id, ..., stops ]
				my @parts = ();

				my ($trip_number)
					= ( $twig->get_xpath( 'div[@id="tul"]/h2', 0 )->text =~ m/(\d+)/ );
				my $trip_short_name = $twig->get_xpath( 'div[@id="tul"]/h2', 0 )->copy;
				$trip_short_name->cut_children('#ELT');
				$trip_short_name = $trip_short_name->text;
				$trip_short_name =~ s/^\s*(.*?)\s*$/$1/g;
				$trip_short_name =~ s/\s*\(.*?\)//g;
				($trip_short_name) = ( $trip_short_name =~ m/(\d+)/ );

=pod

Stop times.

	<tr class="l">
		<td>1230</td>
		<td style="text-align:left">
			<a onclick="ELVIRA.AF(1564,'09.02.01');return false" href="af?i=1564&amp;d=09.02.01&amp;language=1&amp;ed=497F03CF">Hmelniki</a>
		</td>
		<td>15:10</td>
		<td>15:20</td>
		<td></td>
	</tr>

	<tr class="l">
		<td>1230</td>
		<td style="text-align:left">
			<a onclick="ELVIRA.AF(1564,'09.02.01');return false" href="af?i=1564&amp;d=09.02.01&amp;language=1&amp;ed=497F03CF">Hmelniki</a>
		</td>
		<td>15:10</td>
		<td>15:20</td>
		<td></td>
		<td></td>
		<td>15:10</td>
		<td>15:20</td>
		<td></td>
	</tr>

=cut

				### Process first, since this is needed for processing the rest....
				my $prev = 0;
				foreach my $stop (
					$twig->get_xpath('div[@id="menetrend"]/table/tbody/tr[@class="l"]') )
				{

					my ( $dist, $name, $arr, $dep, $platform, $extra );
					my @td = $stop->get_xpath('td');
					( $dist, $name, $arr, $dep ) = map { $_->text } @td[ 0 .. 3 ];
					$platform = $td[-2]->text;
					$extra    = $td[-1];

					undef $platform unless $platform =~ m/^\d+$/;

					my $pickup_type    # csak leszállás cléjábol
						= eval {
						$extra->get_xpath(
							'img[@src="http://elvira.mav-start.hu/fontgif/369.gif"]', 0 );
						}
						? 1
						: 0;
					my $drop_off_type    # csak felszállás cléjábol
						= eval {
						$extra->get_xpath(
							'img[@src="http://elvira.mav-start.hu/fontgif/370.gif"]', 0 );
						}
						? 1
						: 0;

					$arr = '' unless $arr =~ s/^.*?(\d+:\d+).*?$/$1/;
					$dep = '' unless $dep =~ s/^.*?(\d+:\d+).*?$/$1/;

					my ($t) = ( $arr =~ /(\d+):\d+/ );
					$t = 0 unless defined $t;
					if ( $t < $prev ) {
						$t += 24 while $t < $prev;
						$arr =~ s/\d+/$t/;
					}
					$prev = $t;
					($t) = ( $dep =~ /(\d+):\d+/ );
					$t = 0 unless defined $t;
					if ( $t < $prev ) {
						$t += 24 while $t < $prev;
						$dep =~ s/\d+/$t/;
					}
					$prev = $t;

					$dep = $arr if !$dep;
					$arr = $dep if !$arr;

					$arr =~ s/^(\d):/0$1:/;
					$dep =~ s/^(\d):/0$1:/;

					$arr .= ':00';
					$dep .= ':00';

					my $stop_id = handler_stop( $twig, $stop->get_xpath( 'td/a', 0 ) );

					push @$stops,
					[
						$name, $arr,         $dep,           $stop_id,
						$dist, $pickup_type, $drop_off_type, $platform
						];
				}

				for my $i (0 .. $#$stops) {
					my $stop = $stops->[$i];
					next if $stop->[7];

					$stop->[7] = guess_platform(
						$trip_short_name,
						$stop->[0],
						$stops->[0][0],
						$stops->[-1][0],
						$i > 0        ? $stops->[ $i - 1 ][0] : undef,
						$i < $#$stops ? $stops->[ $i + 1 ][0] : undef,
					);
				}

				if ( $self->ignore_non_hungarian ) {
					my $found = 0;
					foreach my $stop (@$stops) {
						if ( $STOP_CODE->{ $stop->[0] } || $BORDER_STATIONS->{ $stop->[0] } ) {
							$found = 1;
						}

					}
					unless ($found) {
						$log->debug("Skipped non-hungarian $elvira_trip_id");

						goto FINISH;
					}
				}

=pod

Handles timetable header definitions

	<div id="tul">
		<h2>566 RÓZSA <img src="/fontgif/323.gif" alt="InterCity"></h2> /* number - name - type */
		<h3>Budapest-Keleti pu. - Budapest-Nyugati pu.</h3> /* from - to */
		<br>
		<br>
	</div>

	<div id="tul">
		<h2>39012</h2>
		<h4>
			<ul>
				<li>Rédics - Bak: <span style="color:#000000">személyvonat</span></li>
				<li>Bak - Zalaegerszeg: <span style="color:#800080">vonatpótló autóbusz</span></li>
			</ul>
		</h4>
		<h3>Rédics - Zalaegerszeg</h3>
		<br>
		<br>
		Rédics - Zalaegerszeg pályaépítési munkák! (2009.03.17 - 2009.03.25 és 2009.03.31 - 2009.04.05)
	</div>

=cut

				# RJ IC S EN

				if (   $twig->get_xpath( 'div[@id="tul"]/h4', 0 )
					&& $twig->get_xpath( 'div[@id="tul"]/h4', 0 )->text ne 'megjegyzés:' )
				{
					my $part_number = 1;

					foreach (
						$twig->get_xpath('div[@id="tul"]/h4/ul/li'),
						$twig->get_xpath('div[@id="tul"]/ul[0]/li')
						)
					{
						my $text       = $_->text;
						my @part_stops = ();
						my ( $from, $to ) = ( $text =~ m/^(.*?) - (.*?):/ );

						my $temp_route_id = $_->get_xpath( 'span', 0 );
						if ($temp_route_id) {
							$temp_route_id = $temp_route_id->text;
						}
						else {
							$temp_route_id = $_->get_xpath( 'img', 0 )->att('alt');
						}

						@part_stops = limit_stops( $stops, $from, $to );

						my $route_id = $routes->{$temp_route_id}->{route_id};

						$trip_short_name = "IC $trip_short_name"
							if $trip_short_name =~ m/^\d+$/ && $route_id eq 'INTERCITY';
						$trip_short_name = "EN $trip_short_name"
							if $trip_short_name =~ m/^\d+$/ && $route_id eq 'EURONIGHT';
						$trip_short_name = "rj $trip_short_name"
							if $trip_short_name =~ m/^\d+$/ && $route_id eq 'RAILJET';
						$trip_short_name = "S $trip_short_name"
							if $trip_short_name =~ m/^\d+$/ && $route_id eq 'SEBES';

						confess "Unknown train type: <$temp_route_id>\n"
							. Dumper( [ keys %$routes ] )
							unless $route_id;

						push @parts,
							[
							$routes->{$temp_route_id}->{route_id},
							'MT_' . $trip_number . '_' . $elvira_trip_id . '_' . $part_number,
							[@part_stops]
							];

						$part_number++;
					}
				}
				else {
					my $temp_route_id = $twig->get_xpath( 'div[@id="tul"]/h2/span', 0 );
					my $route_id;

					if ($temp_route_id) {
						$temp_route_id = $temp_route_id->text;
					}
					else {
						$temp_route_id
							= (    $twig->get_xpath( 'div[@id="tul"]/h2/img', 0 )
								|| $twig->get_xpath( 'div[@id="tul"]/h2/a/img', 0 ) )
							->att('alt');
					}

					$route_id = $routes->{$temp_route_id}->{route_id};

					$trip_short_name = "IC $trip_short_name"
						if $trip_short_name =~ m/^\d+$/ && $route_id eq 'INTERCITY';
					$trip_short_name = "EN $trip_short_name"
						if $trip_short_name =~ m/^\d+$/ && $route_id eq 'EURONIGHT';
					$trip_short_name = "rj $trip_short_name"
						if $trip_short_name =~ m/^\d+$/ && $route_id eq 'RAILJET';
					$trip_short_name = "S $trip_short_name"
						if $trip_short_name =~ m/^\d+$/ && $route_id eq 'SEBES';

					confess "Unknown train type: <$temp_route_id>" . Dumper( [ keys %$routes ] )
						unless $route_id;

					push @parts,
						[ $route_id, 'MT_' . $trip_number . '_' . $elvira_trip_id, [@$stops] ];
				}

				foreach my $p (@parts) {
					my $stops = $p->[2];
					foreach my $s (@$stops) {
						if ( $s->[7] ) {
							$PLATFORMS->{ $s->[0] }->{$trip_short_name} = $s->[7];
						}
					}
				}

=pod

Services [ add as trip_desc? ]

	<div id="szolgaltatasok" class="rtf">
		<h5>szolgáltatás:</h5>
		<ul>
			<li><img src="/fontgif/43.gif" title="" alt=""> Helyjegy váltása kötelező</li>
			<li><img src="/fontgif/51.gif" title="" alt=""> Étkezőkocsi</li>
			<li><img src="/fontgif/367.gif" title="" alt=""> Dohányzás az arra kijelölt kocsiban</li>
			<li><img src="/fontgif/609.gif" title="" alt=""> Rendkívüli helyzet alkalmával közlekedő vonat</li>
		</ul>
	</div>

	<div id="szolgaltatasok" class="rtf">
		<ul>
			<li class="lh">on-board services:</li>
			<li><img src="/fontgif/631.gif" title="" alt=""> The train can be made useing of Budapest Season Ticket (BB):<br><strong>Budapest-Déli - Tatabánya</strong></li>
			<li><img src="/fontgif/36.gif" title="" alt=""> Second Class only</li>
			<li><img src="/fontgif/61.gif" title="" alt=""> Bicycles can be transported in the suitable coach.</li>
			<li><img src="/fontgif/627.gif" title="" alt=""> No-smoking train</li>
			<li><img src="/fontgif/609.gif" title="" alt=""> Train running due to extraordinaly situation.</li>
			<li><img src="/fontgif/684.gif" title="" alt=""> Car available for passengers with Wheelchair without elevator</li>
			<li><img src="/fontgif/319.gif" title="" alt=""> Car available for passengers with Wheelchair with elevator</li>
		</ul>
	</div>

=cut

				foreach my $part (@parts) {
					my $trip_bikes_allowed = 0;
					my $bb                 = $twig->get_xpath(
						'div[@id="szolgaltatasok"]/ul/li/img[@src="http://elvira.mav-start.hu/fontgif/631.gif"]',
						0
					);

					if ($bb) {
						my ( $from, $to );
						foreach my $s (@$stops) {
							if(!$from && ($BB_STOPS->{$s->[0]} || $BB_BORDER_STOPS->{$s->[0]})) {
								$from = $s->[0];
							}
							if( $from && ($BB_STOPS->{$s->[0]} || $BB_BORDER_STOPS->{$s->[0]})) {
								$to = $s->[0];
							}
						}

						if($to && $from) {
							if($BB_STOPS->{$from} && $BB_STOPS->{$to}) {
								$from = $stops->[ 0]->[0];
								$to   = $stops->[-1]->[0];
							}

							foreach my $s (@$stops) {
								undef $from if ( $from && $s->[0] eq $from );
								if ( !$from && $to ) {
									my $stop_id = $s->[3];
									my $zones   = (
										$BB_STOPS->{ $s->[0] }
										? 'BKSZ,MAV'
										: 'BKSZ_DISCOUNT,MAV'
									);
									$STOPS->{$stop_id}->{zone_id} = $zones;
								}

								last if $to eq $s->[0];
							}
						}
					}

					# Bikes
					if (
						$twig->get_xpath(
							'div[@id="szolgaltatasok"]/ul/li/img[@src="http://elvira.mav-start.hu/fontgif/61.gif"]',
							0
						)
						|| $twig->get_xpath(
							'div[@id="szolgaltatasok"]/ul/li/img[@src="http://elvira.mav-start.hu/fontgif/60.gif"]',
							0
						)
						|| $twig->get_xpath(
							'div[@id="szolgaltatasok"]/ul/li/img[@src="http://elvira.mav-start.hu/fontgif/689.gif"]',
							0
						)
						)
					{
						$trip_bikes_allowed = 2;
					}
					if (  !$trip_bikes_allowed
						&& $part->[0] !~ m/^(?:NEMZETKOZI-GYORS|NEMZETKOZI-SZEMELY|EXPRESSZ|BELFOLDI-GYORS|SZEMELY|SEBES)$/ )
					{
						$trip_bikes_allowed = 1;
					}
					if ( $part->[0] =~ m/^(?:VONATPOTLO|ICVP)$/ ) {
						$trip_bikes_allowed = 1;
					}
					$part->[3] = $trip_bikes_allowed;

					# Wheelchair
					if (
						$twig->get_xpath(
							'div[@id="szolgaltatasok"]/ul/li/img[@src="http://elvira.mav-start.hu/fontgif/684.gif"]',
							0
						)
						|| $twig->get_xpath(
							'div[@id="szolgaltatasok"]/ul/li/img[@src="http://elvira.mav-start.hu/fontgif/319.gif"]',
							0
						)
						)
					{
						$part->[4] = 1;
					}
					else {
						$part->[4] = 0;
					}
				}

=pod

Variations: restrict the timetables' validity...

There exists a 'global' variation, which is then subclassed (2008.12.14 -> 2009.12.12: 2009.03.16 -> 2009.03.27)

	<div id="valtozat" class="rtf">
		<ul>
			<li>
				<a href="vt?v=17911&amp;language=1&amp;ed=4E64D836">2010.12.12-2011.12.10</a>
				:
				<span style="font-size:80%">Hivatalos Menetrend 2010-2011</span>
			</li>
			<li style="color:red;font-weight:bolder">*
				<a href="vt?v=17912&amp;language=1&amp;ed=4E64D836">2011.08.26-2011.09.07</a>
				:
				<span style="font-size:80%">Tatabánya - Szárliget pályaépítési munkák I.</span>
			</li>
		</ul>
	</div>

=cut

				if ( $twig->get_xpath('div[@id="valtozat"]/ul') ) {
					$variation_intervals = undef;

					foreach my $li ( $twig->get_xpath('div[@id="valtozat"]/ul/li') ) {
						my $text = $li->get_xpath( 'a', 0 )->text;

						if ( $li->att('style') ) {
							$variation_intervals = {};
							foreach my $interval ( split ' ', $text ) {
								my @date_parts = split /[\.-]/, $interval;
								$variation_intervals->{$_} = 1
									for (
									map { join '', @$_ } negate_dates(
										run_interval(
											[ @date_parts[ 0, 1, 2 ] ],
											[ @date_parts[ 3, 4, 5 ] ]
										)
									)
									);
							}
						}
						elsif ($variation_intervals) {
							foreach my $interval ( split ' ', $text ) {
								my @date_parts = split /[\.-]/, $interval;
								$variation_intervals->{$_} = 1
									for (
									map { join '', @$_ } run_interval(
										[ @date_parts[ 0, 1, 2 ] ],
										[ @date_parts[ 3, 4, 5 ] ]
									)
									);
							}
						}
					}

					$variation_intervals = [ sort keys %$variation_intervals ];
				}
				else {
					$variation_intervals = [];
				}

=pod

Basic restrictions (see pod further down):

	<div id="kozlekedik" class="rtf">
		<h5>közlekedik:</h5>
		<ul>
			<li>naponta</li>
		</ul>
	</div>

Distance restrictions:

	<div id="kozlekedik" class="rtf">
		<h5>közlekedik:</h5>
		<ul>
			<li><span style="font-weight:bold">Kobánya-Kispest - Kiskunhalas</span>: naponta</li>
			<li><span style="font-weight:bold">Kiskunhalas - Kelebia</span>: naponta, de nem közlekedik: 2008.XII.24</li>
		</ul>
	</div>

Stop restrictions:

	<div id="kozlekedik" class="rtf">
		<h5>közlekedik:</h5>
		<ul>
			<li>naponta</li>
			<li><span style="font-weight:bold">Pusztakettős</span>: 2009.V.01-től IX.06-ig  naponta	</li>
		</ul>
	</div>

=cut

				my $errord_service = 0;
				my @timetable      = map {
					unless ( $_->att('class') && $_->att('class') eq 'lh' )
					{

						my ( $exception, $text, $value );
						if ( $exception = $_->get_xpath( 'span', 0 ) ) {
							my $partial = $_->copy;
							$partial->cut_children('#ELT');
							($text)      = ( $partial->text   =~ m/^\s*:\s*(.*)$/ );
							($exception) = ( $exception->text =~ m/^\s*(.*?)\s*$/gm );
							$exception =~ s/\s+/ /gm;
						}
						else {
							$text = $_->text;
						}
						$text =~ s/^\s*(.*?)\s*[,.]*\s*$/$1/;
						$text =~ s/\s+/ /g;
						if ( $exception && $exception =~ m/^(.*?) - (.*?)$/ ) {
							$value = [ $1, $2 ];
						}
						elsif ($exception) {
							$value = $exception;
						}

						my $ret = {
							service_id =>
								create_service_from_text( $text, @$variation_intervals ),
							value => $value,
						};
						unless ( $ret->{service_id} ) {
							$errord_service = 1;
							$log->warn("$elvira_trip_id: unknown operating time >> $text")
								unless length $text > 250;
						}
						$ret;
					}
					else {
						();
					}
				} $twig->get_xpath('div[@id="kozlekedik"]/ul/li');

				for ( my $i = 0; $i <= $#timetable; $i++ ) {
					$timetable[$i]->{restrictions} = [ map { $_->{value} ? $_->{value} : () }
							@timetable[ 0 .. $i - 1, $i + 1 .. $#timetable ] ];
				}
				@timetable = map { delete $_->{value}; $_ } @timetable;

				unless ($errord_service) {

					# asses all possibilites -> have fun (i.e. run for a damned life)
					# A, B => A & B; A \ B; B \ A
					# A, B, C => A & B & C; A \ (B & C); B \ (A & C); C \ (A & B); (A & B) \ C; (A & C) \ B; (B & C) \ A

					if ( scalar @timetable == 1 ) {
						foreach my $part (@parts) {
							my ( $route_id, $trip_id, $stops, $trip_bikes_allowed,
								$wheelchair_accessible )
								= @$part;

							create_trip(
								$route_id,                   $trip_id,
								$timetable[0]->{service_id}, $elvira_trip_id,
								$trip_short_name,            $trip_bikes_allowed,
								$wheelchair_accessible,      @$stops
							);
						}
					}
					elsif ( scalar @timetable == 2 ) {
						foreach my $part (@parts) {
							my ( $route_id, $trip_id, $stops, $trip_bikes_allowed,
								$wheelchair_accessible )
								= @$part;
							# A, B =>
							# A + B
							{
								my $service_and = HuGTFS::Cal::and_service(
									$timetable[0]->{service_id},
									$timetable[1]->{service_id},
								);
								create_trip(
									$route_id,                $trip_id . '_AND2',
									$service_and->service_id, $elvira_trip_id,
									$trip_short_name,         $trip_bikes_allowed,
									$wheelchair_accessible,   @$stops
								);
							}
							# A - B
							{
								my $service_a_only = HuGTFS::Cal::subtract_service(
									$timetable[0]->{service_id},
									$timetable[1]->{service_id},
								);
								create_trip(
									$route_id,
									$trip_id . '_ONLY2-1',
									$service_a_only->service_id,
									$elvira_trip_id,
									$trip_short_name,
									$trip_bikes_allowed,
									$wheelchair_accessible,
									restrict_stops(
										$stops, @{ $timetable[0]->{restrictions} }
									)
								);
							}
							# B - A
							{
								my $service_b_only = HuGTFS::Cal::subtract_service(
									$timetable[1]->{service_id},
									$timetable[0]->{service_id},
								);
								create_trip(
									$route_id,
									$trip_id . '_ONLY2-2',
									$service_b_only->service_id,
									$elvira_trip_id,
									$trip_short_name,
									$trip_bikes_allowed,
									$wheelchair_accessible,
									restrict_stops(
										$stops, @{ $timetable[1]->{restrictions} }
									)
								);
							}
						}
					}
					elsif ( 0 && scalar @timetable == 3 ) {
						foreach my $part (@parts) {
							my ( $route_id, $trip_id, $stops, $trip_bikes_allowed,
								$wheelchair_accessible )
								= @$part;

							# A, B, C =>
							#   A - B - C
							{
								my $service_a_only = HuGTFS::Cal::subtract_service(
									$timetable[0]->{service_id},
									$timetable[1]->{service_id},
								);
								$service_a_only = HuGTFS::Cal::subtract_service(
									$service_a_only,
									$timetable[2]->{service_id},
								);
								create_trip(
									$route_id,
									$trip_id . '_ONLY1-2_3',
									$service_a_only->service_id,
									$elvira_trip_id,
									$trip_short_name,
									$trip_bikes_allowed,
									$wheelchair_accessible,
									restrict_stops(
										$stops, @{ $timetable[0]->{restrictions} }
									)
								);
							}
							#   B - A - C
							{
								my $service_b_only = HuGTFS::Cal::subtract_service(
									$timetable[1]->{service_id},
									$timetable[0]->{service_id},
								);
								$service_b_only = HuGTFS::Cal::subtract_service(
									$service_b_only,
									$timetable[2]->{service_id},
								);
								create_trip(
									$route_id,
									$trip_id . '_ONLY2-1_3',
									$service_b_only->service_id,
									$elvira_trip_id,
									$trip_short_name,
									$trip_bikes_allowed,
									$wheelchair_accessible,
									restrict_stops(
										$stops, @{ $timetable[1]->{restrictions} }
									)
								);
							}
							#   C - A - B
							{
								my $service_a_only = HuGTFS::Cal::subtract_service(
									$timetable[2]->{service_id},
									$timetable[0]->{service_id},
								);
								$service_a_only = HuGTFS::Cal::subtract_service(
									$service_a_only,
									$timetable[1]->{service_id},
								);
								create_trip(
									$route_id,
									$trip_id . '_ONLY3-1_2',
									$service_a_only->service_id,
									$elvira_trip_id,
									$trip_short_name,
									$trip_bikes_allowed,
									$wheelchair_accessible,
									restrict_stops(
										$stops, @{ $timetable[2]->{restrictions} }
									)
								);
							}
							#   A + B - C
							{
								my $service_ab_only = HuGTFS::Cal::and_service(
									$timetable[0]->{service_id},
									$timetable[1]->{service_id},
								);
								$service_ab_only = HuGTFS::Cal::subtract_service(
									$service_ab_only,
									$timetable[2]->{service_id},
								);
								create_trip(
									$route_id,
									$trip_id . '_ONLY1_2-3',
									$service_ab_only->service_id,
									$elvira_trip_id,
									$trip_short_name,
									$trip_bikes_allowed,
									$wheelchair_accessible,
									restrict_stops(
										$stops, and_restrict($timetable[0]->{restrictions}, $timetable[1]->{restrictions}),
									)
								);
							}
							#   A + C - B
							{
								my $service_ac_only = HuGTFS::Cal::and_service(
									$timetable[0]->{service_id},
									$timetable[2]->{service_id},
								);
								$service_ac_only = HuGTFS::Cal::subtract_service(
									$service_ac_only,
									$timetable[1]->{service_id},
								);
								create_trip(
									$route_id,
									$trip_id . '_ONLY1_3-2',
									$service_ac_only->service_id,
									$elvira_trip_id,
									$trip_short_name,
									$trip_bikes_allowed,
									$wheelchair_accessible,
									restrict_stops(
										$stops, and_restrict($timetable[0]->{restrictions}, $timetable[2]->{restrictions}),
									)
								);
							}
							#   B + C - A
							{
								my $service_bc_only = HuGTFS::Cal::and_service(
									$timetable[1]->{service_id},
									$timetable[2]->{service_id},
								);
								$service_bc_only = HuGTFS::Cal::subtract_service(
									$service_bc_only,
									$timetable[0]->{service_id},
								);
								create_trip(
									$route_id,
									$trip_id . '_ONLY2_3-1',
									$service_bc_only->service_id,
									$elvira_trip_id,
									$trip_short_name,
									$trip_bikes_allowed,
									$wheelchair_accessible,
									restrict_stops(
										$stops, and_restrict($timetable[1]->{restrictions}, $timetable[2]->{restrictions}),
									)
								);
							}
							#   A + B + C
							{

								my $service_and = HuGTFS::Cal::and_service(
									$timetable[0]->{service_id},
									$timetable[1]->{service_id},
								);
								$service_and = HuGTFS::Cal::and_service(
									$service_and,
									$timetable[2]->{service_id},
								);
								create_trip(
									$route_id,                $trip_id . '_AND3',
									$service_and->service_id, $elvira_trip_id,
									$trip_short_name,         $trip_bikes_allowed,
									$wheelchair_accessible,   @$stops
								);
							}
						}
					}
					else {
						$log->warn(
							"$elvira_trip_id: Can't find a living chicken, dammit!!! -> "
								. scalar @timetable );

						foreach my $part (@parts) {
							my ( $route_id, $trip_id, $stops, $trip_bikes_allowed,
								$wheelchair_accessible )
								= @$part;

							create_trip( $route_id, $trip_id, 'M_DUNNO', $elvira_trip_id,
								$trip_short_name, $trip_bikes_allowed, $wheelchair_accessible,
								@$stops );
						}
					}
				}
				else {
					foreach my $part (@parts) {
						my ( $route_id, $trip_id, $stops, $trip_bikes_allowed,
							$wheelchair_accessible )
							= @$part;

						create_trip( $route_id, $trip_id, 'M_DUNNO', $elvira_trip_id,
							$trip_short_name, $trip_bikes_allowed, $wheelchair_accessible,
							@$stops );
					}
				}

			FINISH:
				$twig->purge;

				$q++;
			};

			#last if $ARGV[0] && $q >= $ARGV[0];

			if ($@) {
				$log->warn("Failed to parse ${elvira_trip_id}: $@");
			}
		}
	}

	{
		my %visited_stops = ();
		foreach my $trip (@$TRIPS) {
			foreach my $stop_time ( @{ $trip->{stop_times} } ) {
				$visited_stops{ $stop_time->{stop_id} } = 1;
			}
		}
		foreach my $stop ( keys %$STOPS ) {
			delete $STOPS->{$stop} unless $visited_stops{$stop};
		}
	}

	sub create_trip
	{
		my ( $route_id, $trip_id, $service, $elvira_trip_id, $trip_short_name,
			$trip_bikes_allowed, $wheelchair_accessible )
			= ( shift, shift, shift, shift, shift, shift, shift );
		my @stops = @_;

		return if $service eq 'NEVER';

		my ( $i, $dist_diff, $last, @stop_times ) = (1);
		foreach my $stop (@stops) {
			if ( $self->ignore_non_hungarian ) {
				next
					unless $STOP_CODE->{ $stop->[0] } || $BORDER_STATIONS->{ $stop->[0] };
			}
			$dist_diff = $stop->[4] unless defined $dist_diff;

			my ( $name, $arr, $dep, $stop_id, $dist, $pickup_type, $drop_off_type ) = @$stop;
			push(
				@stop_times,
				{
					arrival_time   => $arr ? $arr : undef,
					departure_time => $dep ? $dep : undef,
					stop_id        => $stop_id,
					shape_dist_traveled => $dist - $dist_diff,
					pickup_type         => $pickup_type,
					drop_off_type       => $drop_off_type,
				}
			);

			$last = $stop;
			$i++;
		}

		return unless scalar @stop_times > 1;

		push @$TRIPS, {
			route_id     => $route_id,
			service_id   => $service,
			direction_id => ( $trip_short_name =~ m/(\d+)/ )[0] % 2
			? 'inbound'
			: 'outbound',    # most of the time even = outbound, odd = inbound
			trip_id       => $trip_id,
			trip_headsign => $last == $stops[-1]
			? $stops[$#stops]->[0]
			: $last->[0] . ' (' . $stops[-1]->[0] . ')',
			trip_short_name       => $trip_short_name,
			trip_url              => $self->reference_url . "trip_${elvira_trip_id}.html",
			stop_times            => \@stop_times,
			trip_bikes_allowed    => $trip_bikes_allowed,
			wheelchair_accessible => $wheelchair_accessible,
		};

	}

	sub handler_stop
	{
		my ( $t, $section ) = @_;
		my $name = $section->trimmed_text;

		my $stop_elvira_id = ( $section->att('href') =~ /(\d+)/ )[0];
		my $id = $STOP_CODE->{$name} || "MSE_$stop_elvira_id";

		my $stop = $STOPS->{$id};

		if ( !$stop ) {
			### This will be of use once stop_areas exist in OSM
			### [ station = stop_area name + center; stops = halts ]
			my $type = $STOP_TYPE->{$id} || 'station';

			# XXX Name sanitizing ->
			# 						Hbf ~ Hauptbahnhof
			# 						A.D ~ an der
			#						Süd ~ Südbahnhof
			#						Ost ~ Ostbahn

			my $code = $STOP_CODE->{$name};
			$code = 'V' . $1 if $code && $code =~ m/^55(\d{5})$/;

			$STOPS->{$id} = $stop = {

				#elvira_name => $name,
				stop_id       => $id,
				zone_id       => 'MAV',
				stop_code     => $code,
				stop_url      => $self->reference_url . "/station_${stop_elvira_id}.html",
				location_type => 0,

				#stop_type     => 'stop',
				# "$ELVIRA/xslvzs/af?mind=1&i=$stop_elvira_id",
			};

			$name =~ s/\bA\.D\.\s*/an der /;
			$name =~ s/\bHbf\b/Hauptbahnhof/;
			$name =~ s/\bSüdbf\b/Südbahnhof/;
			$name =~ s/\bWestbf\b/Westbahnhof/;
			$name =~ s/\bKöflacherbf\b/Köflacherbahnhof/;
			$name =~ s/\s*\(Ost\)/ (Ostbahn)/;
			$name =~ s/St\.\s*/St. /;

			$name =~ s/\s*\((?:Gkb|Ch|Roeee)\)//;
			$stop->{stop_name} = $name;

=pod
		if ( $type eq 'station' ) {
			$STOPS->{ 'MSS_' . $id } = {
				stop_name => $name,
				stop_id   => 'MSS_' . $id,
				stop_type => 'station',
				stop_code => $stop_elvira_id,
				stop_url =>
					"$ELVIRA/xslvzs/af?mind=1&i=$stop_elvira_id",
				location_type => 1,
			};
			$STOPS->{$id}->{parent_station} = 'MSS_' . $id;
		}
=cut

		}

		return $id;
	}
}

sub limit_stops {
	my ($stops, $from, $to) = @_;
	my @new_stops;

	for(@$stops) {
		if(!$from || $from eq $_->[0]) {
			push @new_stops, $_;
			undef $from;
		}

		last if($to eq $_->[0]);
	}

	return @new_stops;
}

sub restrict_stops
{
	my ( $stops, @restrictions ) = @_;
	my (@new_stops);

	# merge
	@restrictions = merge_restrict(@restrictions);

	my $restrict = pop @restrictions;
	return @$stops unless $restrict;

	if (@restrictions) {
		$stops = [ restrict_stops( $stops, @restrictions ) ];
	}

	if ( ref $restrict ) {
		my ( $from, $to ) = @$restrict;

		foreach my $stop (@$stops) {
			if($from && $stop->[0] eq $from) {
				$from = undef;

				push @new_stops, $stop
					unless $stops->[0] == $stop;
			} elsif( $from ) {
				push @new_stops, $stop;
			}

			if ( !$from && !$to ) {
				push @new_stops, $stop;
			}
			elsif ( !$from && $stop->[0] eq $to ) {
				$to = undef;

				push @new_stops, $stop
					unless $stop == $stops->[-1];
			}
		}
	}
	else {
		foreach my $stop (@$stops) {
			unless ( $stop->[0] eq $restrict ) {
				push @new_stops, $stop;
			}
		}
	}
	return @new_stops;
}

sub merge_restrict
{
	my @restrictions = @_;
	for ( my $i = $#restrictions; $i >= 1; --$i ) {
		if ( ref $restrictions[$i] && ref $restrictions[ $i - 1 ] ) {
			if ( $restrictions[$i][0] eq $restrictions[ $i - 1 ][1] ) {
				splice( @restrictions, $i - 1, 2,
					[ $restrictions[ $i - 1 ][0], $restrictions[$i][1] ] );
			}
		}
	}

	return @restrictions;
}

sub and_restrict
{
	my ( $a, $b ) = @_;
	my $r = { map { ( ref $_ ? "$_->[0] - $_->[1]" : $_ ) => $_ } @$a };

	my @ret;

	for (@$b) {
		push @ret, $_ if $r->{ ref $_ ? "$_->[0] - $_->[1]" : $_ };
	}

	return @ret;
}

sub guess_platform
{
	my ( $trip_short_name, $stop, $from, $to, $prev, $next ) = @_;

#<<<
	state $even_odd_platform = {
		'Albertfalva'          => [qw/1 2/],
		'Angyalföld'           => [qw/5 4/],
		'Barosstelep'          => [qw/A B/],
		'Budaörs'              => [qw/3 4/],
		'Budatétény'           => [qw/A B/],
		'Érdliget'             => [qw/A B/],
		'Istvántelek'          => [qw/B A/],
		'Kispest'              => [qw/3 2/],
		'Nagytétény'           => [qw/1 2/],
		'Nagytétény-Diósd'     => [qw/4 3/],
		'Óbuda'                => [qw/4 3/],
		'Pestszentimre'        => [qw/2 1/],
		'Pestszentlőrinc'      => [qw/1 2/],
		'Rákoscsaba'           => [qw/1 2/],
		'Rákoscsaba-Újtelep'   => [qw/1 2/],
		'Rákoshegy'            => [qw/3 4/],
		'Rákoskert'            => [qw/2 1/],
		'Rákosliget'           => [qw/1 2/],
		'Soroksár'             => [qw/2 3/],
		'Soroksári út'         => [qw/2 3/],
		'Szemeretelep'         => [qw/2 1/],
		'Törökbálint'          => [qw/B A/],
		'Vasútmúzeum'          => [qw/B A/],
	};

	state $special = {
		'Budafok' => [
			['prev',      ['Budatétény', 'Érd felső', 'Barosstelep', 'Nagytétény-Diósd', 'Háros', 'Érdliget'], 2],
			['next',      ['Budatétény', 'Érd felső', 'Barosstelep', 'Nagytétény-Diósd', 'Háros', 'Érdliget'], 1],
			['prev-next', ['Érd alsó', 'Tétényliget', 'Nagytétény',  'Albertfalva',                ], 3],
			['from-to', [
				['Kelenföld', 'Dunaújváros'],
				['Kelenföld', 'Pusztaszabolcs'],
				['Budapest-Déli', 'Dunaújváros'],
				['Budapest-Déli', 'Pusztaszabolcs'],
				['Budapest-Déli', 'Százhalombatta']],
			1],
			['to-from', [
				['Kelenföld', 'Dunaújváros'],
				['Kelenföld', 'Pusztaszabolcs'],
				['Budapest-Déli', 'Dunaújváros'],
				['Budapest-Déli', 'Pusztaszabolcs'],
				['Budapest-Déli', 'Százhalombatta'],],
			2],
			['any-any', [
				['Kelenföld', 'Martonvásár'],
				['Budapest-Déli', 'Fonyód'],
				['Budapest-Déli', 'Keszthely'],
				['Budapest-Déli', 'Martonvásár'],
				['Budapest-Déli', 'Nagykanizsa'],
				['Budapest-Déli', 'Siófok'],
				['Budapest-Déli', 'Székesfehérvár'],],
			3],
		],
		'Érd felső', [
			['from', [qw/Budapest-Déli Kelenföld Miskolc-Tiszai Záhony/], 'A'],
			['to',   [qw/Budapest-Déli Kelenföld Miskolc-Tiszai Záhony/], 'B'],
		],
		'Ferihegy' => [
			[ 'from', [qw/Budapest-Keleti Budapest-Nyugati Kőbánya-Kispest Fonyód Keszthely Tapolca/], 'A'],
			[ 'to',   [qw/Budapest-Keleti Budapest-Nyugati Kőbánya-Kispest Fonyód Keszthely Tapolca/], 'B'],
		],
		'Kőbánya alsó' => [
			[ 'to', [qw/Budapest-Nyugati/], 'B'],
			[ 'from', [qw/Budapest-Nyugati/], 'A'],
		],
		'Kőbánya felső' => [
			[ 'next', [qw/Budapest-Keleti/], '1'],
			[ 'prev', [qw/Budapest-Keleti/], '2'],
			[ 'next', [qw/Ferencváros/], '3'],
			[ 'prev', [qw/Ferencváros/], '4'],
		],
		'Rákos' => [
			['from-to', [[qw/Budapest-Keleti Sülysáp/],[qw/Budapest-Keleti Szolnok/],[qw/Budapest-Keleti Nagykáta/]], 2],
			['to-from', [[qw/Budapest-Keleti Sülysáp/],[qw/Budapest-Keleti Szolnok/],[qw/Budapest-Keleti Nagykáta/]], 3],
			['from',    [ qw/Budapest-Keleti Keszthely Miskolc-Tiszai/], 4],
			['to',      [ qw/Budapest-Keleti Keszthely Miskolc-Tiszai/], 5],
		],
		'Rákospalota-Újpest' => [
			['to',   ['Budapest-Keleti'], 3],
			['from', ['Budapest-Keleti'], 4],
			['from-to', [[qw/Szob Budapest-Nyugati/], [qw/Vác Budapest-Nyugati/]], 3],
			['to-from', [[qw/Szob Budapest-Nyugati/], [qw/Vác Budapest-Nyugati/]], 4],
			['from-to', [[qw/Vácrátót Budapest-Nyugati/]], 5],
		],
		'Veszprém' => [
			[ 'any-any', [[qw/Celldömölk Veszprém/], [qw/Szombathely Veszprém/]], 2],
			[ 'to',   ['Budapest-Déli'], 3],
			[ 'from', ['Budapest-Déli'], 4],
			[ 'to-from', [[qw/Székesfehérvár Szombathely/]], '3'],
			[ 'from-to', [[qw/Székesfehérvár Szombathely/]], '4'],
			[ 'any-any', [[qw/Székesfehérvár Veszprém/]], '4A'],
			[ 'any-any', [[qw/Győr Veszprém/]], '4B'],
		],
		'Zugló' => [
			['to',   ['Budapest-Nyugati'], 'A'],
			['from', ['Budapest-Nyugati'], 'B'],
		],
#>>>
	};

	if ( $even_odd_platform->{$stop} ) {
		state $heuristic = {};

		my $even_odd = $trip_short_name % 2;
		my $platform = $even_odd_platform->{$stop}->[$even_odd];

		if (
			(
				defined $heuristic->{$stop}->{to}->{$to}
				&& $heuristic->{$stop}->{to}->{$to} != $even_odd
			)
			|| ( defined $heuristic->{$stop}->{from}->{$from}
				&& $heuristic->{$stop}->{from}->{$from} != $even_odd )
			)
		{
			$log->warn(
				"Platform guessing: $trip_short_name fails e/d deterministic heuristic (s: $stop, f: $from, t: $to)"
			);
		}
		else {
			$heuristic->{$stop}->{to}->{$to}     = $even_odd;
			$heuristic->{$stop}->{from}->{$from} = $even_odd;
		}

		return $platform;
	}

	if ( $special->{$stop} ) {
		foreach ( @{ $special->{$stop} } ) {
			my ( $type, $values, $platform ) = @$_;

			foreach my $v (@$values) {
				given ($type) {
					when ('from') {
						return $platform if $v eq $from;
					}
					when ('to') {
						return $platform if $v eq $to;
					}
					when ('from-to') {
						return $platform if $v->[0] eq $from && $v->[1] eq $to;
					}
					when ('to-from') {
						return $platform if $v->[0] eq $to && $v->[1] eq $from;
					}
					when ('any-any') {
						return $platform
							if ( $v->[0] eq $from && $v->[1] eq $to )
							|| ( $v->[0] eq $to && $v->[1] eq $from );
					}
					when ('prev') {
						return $platform if $prev && $v eq $prev;
					}
					when ('next') {
						return $platform if $next && $v eq $next;
					}
					when ('prev-next') {
						return $platform if ($next && $v eq $next) || ($prev && $v eq $prev);
					}
					default {
						$log->warn("Platform guessing: unknown rule type $_");
					}
				}
			}
		}

		$log->warn("Platform guessing: failed, $trip_short_name (s: $stop, f: $from, t: $to)");
	}

	return undef;
}

=head2 init_cal

Intializes the calendar with default service periods & exceptions.

=cut

sub init_cal
{
	HuGTFS::Cal->empty;

	%R_MONTH = (
		'I'    => '01',
		'II'   => '02',
		'III'  => '03',
		'IV'   => '04',
		'V'    => '05',
		'VI'   => '06',
		'VII'  => '07',
		'VIII' => '08',
		'IX'   => '09',
		'X'    => '10',
		'XI'   => '11',
		'XII'  => '12',
	);

### DATEMOD: This needs a revamp each year...

	$SERVICE_MAP = {};

	$log->info("Creating calendar...");

#<<<
	my $data = [
		[
			qw/service_id monday tuesday wednesday thursday friday saturday sunday start_date end_date service_desc/
		],

		[
			["vasárnapi és ünnepnapi közlekedési rend szerint",
				"vasárnap és ünnepnap",
				"Nem közlekedik: vasárnap és ünnepnap kivételével naponta",],
			'M_+', 0, 0, 0, 0, 0, 0, 1, CAL_START, CAL_END,
		],

		[
			["Nem közlekedik: vasárnapi és ünnepnapi közlekedési rend szerint",
				"Nem közlekedik: vasárnapi és ünnepnapi közlekedési rendszerint",
				"Nem közlekedik: vasárnap és ünnepnap",
				"Nem közl.:vasárnap és ünnepnap",
				"Nem közlekedik: vasárnap és ünnepnapi közlekedési rend szerint",],
			'M_X', 1, 1, 1, 1, 1, 1, 0, CAL_START, CAL_END,
		],

		[
			["munkanap"],
			'M_A', 1, 1, 1, 1, 1, 0, 0, CAL_START, CAL_END,
		],

		[
			["munkanap és vasárnapi közlekedési rend szerint",
				"munkanap és vasárnap közlekedési rend szerint" ],
			'M_B', 1, 1, 1, 1, 1, 0, 1, CAL_START, CAL_END,
		],

		[
			["szombati, vasárnapi és ünnepnapi közlekedési rend szerint",
				"szombat, vasárnap és ünnepnapi közlekedési rend szerint",],
			'M_C', 0, 0, 0, 0, 0, 1, 1, CAL_START, CAL_END,
		],

		[
			["szombati és ünnepnapi közlekedési rend szerint",
				"szombati és ümmepnapi közlekedési rend szerint",
				"hétfőtől csütörtökig tartó közlekedési rend szerint és vasárnapi közlekedési rend szerint kivételével naponta",],
			'M_D', 0, 0, 0, 0, 0, 1, 0, CAL_START, CAL_END,
		],

		[
			["munkanap, de nem közlekedik pénteki közlekedési rend szerint",
				"pénteki közlekedési rend szerint kivételével munkanap",
				"hétfőtől csütörtökig tartó közlekedési rend szerint",],
			'M_4', 1, 1, 1, 1, 0, 0, 0, CAL_START, CAL_END,
		],

		[
			["pénteki közlekedési rend szerint",
				"pénteki közlekedési rend",],
			'M_5', 0, 0, 0, 0, 1, 0, 0, CAL_START, CAL_END,
		],

		[
			["szombati közlekedési rend szerint"],
			'M_6', 0, 0, 0, 0, 0, 1, 0, CAL_START, CAL_END,
		],

		[
			["vasárnapi közlekedési rend szerint"],
			'M_7', 0, 0, 0, 0, 0, 0, 1, CAL_START, CAL_END,
		],

		[
			["Nem közlekedik: pénteki közlekedési rend szerint",
				"pénteki közlekedési rend szerint kivételével naponta",],
			'M_25', 1, 1, 1, 1, 0, 1, 1, CAL_START, CAL_END,
		],

		[
			["Nem közlekedik: szombati közlekedési rend szerint",
				"szombati közlekedési rend szerint kivételével naponta",],
			'M_26', 1, 1, 1, 1, 1, 0, 1, CAL_START, CAL_END,
		],

		[
			["Nem közlekedik: vasárnapi közlekedési rend szerint",
				"vasárnapi közlekedési rend szerint kivételével naponta",
				"vasárnapi közlekedési rend szerint kivételével",],
			'M_27', 1, 1, 1, 1, 1, 1, 0, CAL_START, CAL_END,
		],

		### Custom
		[
			["pénteki, szombati, vasárnapi és ünnepnapi közlekedési rend szerint",
				"pénteki, szombat, vasárnap és ünnepnapi közlekedési rend szerint",
				"péntek, szombat, vasárnap és ünnepnapi közlekedési rend szerint",
				"szombat, vasárnap és ünnepnapi közlekedési rend szerint és péntek",
				"szombat, vasárnap és ünnepnapi közlekedési rend szerint és pénteki közlekedési rend szerint",],
			'M_MC_M5', 0, 0, 0, 0, 1, 1, 1, CAL_START, CAL_END,
		],

		[
			["hétfőtől csütörtökig tartó közlekedési rend szerint és vasárnapi közlekedési rend szerint",],
			'M_M4_M7', 1, 1, 1, 1, 0, 0, 1, CAL_START, CAL_END,
		],

		[
			["szombati közlekedési rend szerint és vasárnapi közlekedési rend szerint",],
			'M_M6_M7', 0, 0, 0, 0, 0, 1, 1, CAL_START, CAL_END,
		],

		[
			["hétfőtől csütörtökig tartó közlekedési rend szerint és vasárnapi közlekedési rend szerint kivételével naponta",
				"hétfőtől csütörtökig tartó közlekedési rend szerint kivételével és vasárnapi közlekedési rend szerint kivételével naponta", ],
			'M_NOT_M4_M7', 0, 0, 0, 0, 1, 1, 0, CAL_START, CAL_END,
		],

		[
			 ["pénteki közlekedési rend szerint és szombati közlekedési rend szerint kivételével naponta",],
			 'M_NOT_M5_M7', 1, 1, 1, 1, 0, 0, 1, CAL_START, CAL_END,
		],

		[
			["ünnepnapi közlekedési rend szerint",],
			'M_U', 0, 0, 0, 0, 0, 0, 0, CAL_START, CAL_END,
		],

		[
			["munkanap kivételével naponta",],
			'M_NOT_A', 0, 0, 0, 0, 0, 1, 1, CAL_START, CAL_END,
		],

		[
			["munkanap és vasárnap közlekedési rend szerint kivételével naponta",],
			'M_NOT_B', 0, 0, 0, 0, 0, 1, 0, CAL_START, CAL_END,
		],

		[
			["pénteki közlekedési rend szerint és vasárnapi közlekedési rend szerint",
				"pénteki és vasárnapi közlekedési rend szerint",],
			'M_M5_M7', 0, 0, 0, 0, 1, 0, 1, CAL_START, CAL_END,
		],

		[
			["pénteki közlekedési rend szerint és vasárnapi közlekedési rend szerint kivételével naponta",],
			'M_NOT_M5_M7', 1, 1, 1, 1, 0, 1, 0, CAL_START, CAL_END,
		],

		[
			["hétfőtől csütörtökig tartó közlekedési rend szerint és szombati és ünnepnapi közlekedési rend szerint",],
			'M_M4_MU', 1, 1, 1, 1, 0, 1, 0, CAL_START, CAL_END,
		],

		### Unspecific cases
		[
			["külön rendeletre", "(egyedi)"],
			'M_0', 0, 0, 0, 0, 0, 0, 0, CAL_START, CAL_END,
		],

		[
			[ "nem tudni, mikulás tudja", ],
			'M_DUNNO', 0, 0, 0, 0, 0, 0, 0, CAL_START, CAL_END,
		],
	];

	my $day_only = [
		[
			qw/service_id monday tuesday wednesday thursday friday saturday sunday start_date end_date service_desc/
		],

		# Official

		[
			["naponta"],
			'M_DAILY', 1, 1, 1, 1, 1, 1, 1, CAL_START, CAL_END,
		],

		[
			["hétfő", "hétfőn", ],
			'M_K1', 1, 0, 0, 0, 0, 0, 0, CAL_START, CAL_END,
		],

		[
			["kedd"],
			'M_K2', 0, 1, 0, 0, 0, 0, 0, CAL_START, CAL_END,
		],

		[
			["szerda"],
			'M_K3', 0, 0, 1, 0, 0, 0, 0, CAL_START, CAL_END,
		],

		[
			["csütörtök"],
			'M_K4', 0, 0, 0, 1, 0, 0, 0, CAL_START, CAL_END,
		],

		[
			["péntek"],
			'M_K5', 0, 0, 0, 0, 1, 0, 0, CAL_START, CAL_END,
		],

		[
			["szombat"],
			'M_K6', 0, 0, 0, 0, 0, 1, 0, CAL_START, CAL_END,
		],

		[
			["vasárnap"],
			'M_K7', 0, 0, 0, 0, 0, 0, 1, CAL_START, CAL_END,
		],

		[
			["nem közlekedik"],
			'M_NK', 0, 0, 0, 0, 0, 0, 0, CAL_START, CAL_END,
		],

		# Implied

		[
			["hétfő, csütörtök, péntek és szombat",],
			'M_DAY_hétfő, csütörtök, péntek és szombat', 1, 0, 0, 1, 1, 1, 0, CAL_START, CAL_END,
		],

		[
			["hétfő, csütörtök, péntek és vasárnap",],
			'M_DAY_hétfő, csütörtök, péntek és vasárnap', 1, 0, 0, 1, 1, 0, 1, CAL_START, CAL_END,
		],

		[
			["hétfő, csütörtök, péntek, szombat és vasárnap",],
			'M_DAY_hétfő, csütörtök, péntek, szombat és vasárnap', 1, 0, 0, 1, 1, 1, 1, CAL_START, CAL_END,
		],

		[
			["hétfő és kedd",],
			'M_DAY_hétfő és kedd', 1, 1, 0, 0, 0, 0, 0, CAL_START, CAL_END,
		],

		[
			["hétfő és csütörtök",],
			'M_DAY_hétfő és csütörtök', 1, 0, 0, 1, 0, 0, 0, CAL_START, CAL_END,
		],

		[
			["hétfő és péntek",],
			'M_DAY_hétfő és péntek', 1, 0, 0, 0, 1, 0, 0, CAL_START, CAL_END,
		],

		[
			["hétfő és szerda",],
			'M_DAY_hétfő és szerda', 1, 0, 1, 0, 0, 0, 0, CAL_START, CAL_END,
		],

		[
			["hétfő és szombat",],
			'M_DAY_hétfő és szombat', 1, 0, 0, 0, 0, 1, 0, CAL_START, CAL_END,
		],

		[
			["hétfő és vasárnap",],
			'M_DAY_hétfő és vasárnap', 1, 0, 0, 0, 0, 0, 1, CAL_START, CAL_END,
		],

		[
			["hétfő, kedd, szerda és csütörtök",
				"hétfő - csütörtök", "hétfő és kedd és szerda és csütörtök",],
			'M_DAY_hétfő, kedd, szerda és csütörtök', 1, 1, 1, 1, 0, 0, 0, CAL_START, CAL_END,
		],

		[
			["hétfő, kedd, csütörtök és szombat",],
			'M_DAY_hétfő, kedd, csütörtök és szombat', 1, 1, 0, 1, 0, 1, 0, CAL_START, CAL_END,
		],

		[
			["hétfő, kedd, csütörtök, péntek és szombat",],
			'M_DAY_hétfő, kedd, csütörtök, péntek és szombat', 1, 1, 0, 1, 1, 1, 0, CAL_START, CAL_END,
		],

		[
			["hétfő, kedd, csütörtök, péntek és vasárnap",],
			'M_DAY_hétfő, kedd, csütörtök, péntek és vasárnap', 1, 1, 0, 1, 1, 0, 1, CAL_START, CAL_END,
		],

		[
			["hétfő, kedd és szerda",],
			'M_DAY_hétfő, kedd és szerda', 1, 1, 1, 0, 0, 0, 0, CAL_START, CAL_END,
		],

		[
			["hétfő, kedd, szerda, csütörtök és péntek",
				'hétfőtől - péntekig'],
			'M_DAY_hétfő, kedd, szerda, csütörtök és péntek', 1, 1, 1, 1, 1, 0, 0, CAL_START, CAL_END,
		],

		[
			["hétfő, kedd, szerda, csütörtök és szombat",],
			'M_DAY_hétfő, kedd, szerda, csütörtök és szombat', 1, 1, 1, 1, 0, 1, 0, CAL_START, CAL_END,
		],

		[
			["hétfő, kedd, szerda, csütörtök és vasárnap",],
			'M_DAY_hétfő, kedd, szerda, csütörtök és vasárnap', 1, 1, 1, 1, 0, 0, 1, CAL_START, CAL_END,
		],

		[
			["hétfő, kedd, szerda és péntek",],
			'M_DAY_hétfő, kedd, szerda és péntek', 1, 1, 1, 0, 1, 0, 0, CAL_START, CAL_END,
		],

		[

			["hétfő, kedd, szerda és vasárnap",
				"hétfő és kedd és szerda és vasárnap"],
			'M_DAY_hétfő, kedd, szerda és vasárnap', 1, 1, 1, 0, 0, 0, 1, CAL_START, CAL_END,
		],

		[
			["hétfő, kedd, szerda, péntek és szombat",
				"hétfő és kedd és szerda és péntek és szombat"],
			'M_DAY_hétfő, kedd, szerda, péntek és szombat', 1, 1, 1, 0, 1, 1, 0, CAL_START, CAL_END,
		],

		[
			["hétfő, kedd, szerda, péntek és vasárnap",],
			'M_DAY_hétfő, kedd, szerda, péntek és vasárnap', 1, 1, 1, 0, 1, 0, 1, CAL_START, CAL_END,
		],

		[
			["hétfő, kedd, szombat és vasárnap",],
			'M_DAY_hétfő, kedd, szombat és vasárnap', 1, 1, 0, 0, 0, 1, 1, CAL_START, CAL_END,
		],

		[
			["hétfő, péntek és vasárnap",],
			'M_DAY_hétfő, péntek és vasárnap', 1, 0, 0, 0, 1, 0, 1, CAL_START, CAL_END,
		],

		[
			["hétfő, péntek, szombat és vasárnap",],
			'M_DAY_hétfő, péntek, szombat és vasárnap', 1, 0, 0, 0, 1, 1, 1, CAL_START, CAL_END,
		],

		[
			["hétfő, szerda, csütörtök és péntek",],
			'M_DAY_hétfő, szerda, csütörtök és péntek', 1, 0, 1, 1, 1, 0, 0, CAL_START, CAL_END,
		],

		[
			["hétfő, szerda, csütörtök, péntek és szombat",],
			'M_DAY_hétfő, szerda, csütörtök, péntek és szombat', 1, 0, 1, 1, 1, 1, 0, CAL_START, CAL_END,
		],

		[
			["hétfő, szerda és vasárnap",],
			'M_DAY_hétfő, szerda és vasárnap', 1, 0, 1, 0, 0, 0, 1, CAL_START, CAL_END,
		],

		[
			["hétfő, szerda - szombat",],
			'M_DAY_hétfő, szerda - szombat', 1, 0, 1, 1, 1, 1, 0, CAL_START, CAL_END,
		],

		[
			["hétfő, szerda, szombat és vasárnap",],
			'M_DAY_hétfő, szerda, szombat és vasárnap', 1, 0, 1, 0, 0, 1, 1, CAL_START, CAL_END,
		],

		[
			["hétfő, szombat és vasárnap",],
			'M_DAY_hétfő, szombat és vasárnap', 1, 0, 0, 0, 0, 1, 1, CAL_START, CAL_END,
		],

		[
			["kedd és szerda",],
			'M_DAY_kedd és szerda', 0, 1, 1, 0, 0, 0, 0, CAL_START, CAL_END,
		],

		[
			["kedd, szerda és csütörtök",],
			'M_DAY_kedd, szerda és csütörtök', 0, 1, 1, 1, 0, 0, 0, CAL_START, CAL_END,
		],

		[
			["kedd, szerda és péntek",],
			'M_DAY_kedd, szerda és péntek', 0, 1, 1, 0, 1, 0, 0, CAL_START, CAL_END,
		],

		[
			["kedd, szerda, péntek, szombat és vasárnap",],
			'M_DAY_kedd, szerda, péntek, szombat és vasárnap', 0, 1, 1, 0, 1, 1, 1, CAL_START, CAL_END,
		],

		[
			["kedd, szerda és szombat",],
			'M_DAY_kedd, szerda és szombat', 0, 1, 1, 0, 0, 1, 0, CAL_START, CAL_END,
		],

		[
			["kedd, szerda, szombat és vasárnap",],
			'M_DAY_kedd, szerda, szombat és vasárnap', 0, 1, 1, 0, 0, 1, 1, CAL_START, CAL_END,
		],

		[
			["kedd, szerda, csütörtök és péntek",],
			'M_DAY_kedd, szerda, csütörtök és péntek', 0, 1, 1, 1, 1, 0, 0, CAL_START, CAL_END,
		],

		[
			["kedd, szerda, csütörtök, péntek és szombat",],
			'M_DAY_kedd, szerda, csütörtök, péntek és szombat', 0, 1, 1, 1, 1, 1, 0, CAL_START, CAL_END,
		],

		[
			["kedd, szerda, csütörtök és szombat",],
			'M_DAY_kedd, szerda, csütörtök és szombat', 0, 1, 1, 1, 0, 1, 0, CAL_START, CAL_END,
		],

		[
			["kedd, csütörtök és péntek",],
			'M_DAY_kedd, csütörtök és péntek', 0, 1, 0, 1, 1, 0, 0, CAL_START, CAL_END,
		],

		[
			["kedd és péntek",],
			'M_DAY_kedd és péntek', 0, 1, 0, 0, 1, 0, 0, CAL_START, CAL_END,
		],

		[
			["kedd, péntek, szombat és vasárnap",],
			'M_DAY_kedd, péntek, szombat és vasárnap', 0, 1, 0, 0, 1, 1, 1, CAL_START, CAL_END,
		],

		[
			["kedd és szombat",],
			'M_DAY_kedd és szombat', 0, 1, 0, 0, 0, 1, 0, CAL_START, CAL_END,
		],

		[
			["kedd, szombat és vasárnap",],
			'M_DAY_kedd, szombat és vasárnap', 0, 1, 0, 0, 0, 1, 1, CAL_START, CAL_END,
		],

		[
			["kedd és vasárnap",],
			'M_DAY_kedd és vasárnap', 0, 1, 0, 0, 0, 0, 1, CAL_START, CAL_END,
		],

		[
			["szerda és csütörtök",],
			'M_DAY_szerda és csütörtök', 0, 0, 1, 1, 0, 0, 0, CAL_START, CAL_END,
		],

		[
			["szerda, csütörtök és péntek",],
			'M_DAY_szerda, csütörtök és péntek', 0, 0, 1, 1, 1, 0, 0, CAL_START, CAL_END,
		],

		[
			["szerda, csütörtök, péntek, szombat és vasárnap",],
			'M_DAY_szerda, csütörtök, péntek, szombat és vasárnap', 0, 0, 1, 1, 1, 1, 1, CAL_START, CAL_END,
		],

		[
			["szerda és péntek",],
			'M_DAY_szerda és péntek', 0, 0, 1, 0, 1, 0, 0, CAL_START, CAL_END,
		],

		[
			["szerda, péntek és szombat",],
			'M_DAY_szerda, péntek és szombat', 0, 0, 1, 0, 1, 1, 0, CAL_START, CAL_END,
		],

		[
			["szerda, péntek és vasárnap",],
			'M_DAY_szerda, péntek és vasárnap', 0, 0, 1, 0, 1, 0, 1, CAL_START, CAL_END,
		],

		[
			["szerda, szombat",
				"szerda és szombat",],
			'M_DAY_szerda és szombat', 0, 0, 1, 0, 0, 1, 0, CAL_START, CAL_END,
		],

		[
			["szerda, szombat és vasárnap",],
			'M_DAY_szerda, szombat és vasárnap', 0, 0, 1, 0, 0, 1, 1, CAL_START, CAL_END,
		],

		[
			["szerda és vasárnap",],
			'M_DAY_szerda és vasárnap', 0, 0, 1, 0, 0, 0, 1, CAL_START, CAL_END,
		],

		[
			["csütörtök és péntek",],
			'M_DAY_csütörtök és péntek', 0, 0, 0, 1, 1, 0, 0, CAL_START, CAL_END,
		],

		[
			["csütörtök, péntek és szombat",
				"csütörtök és péntek és szombat",],
			'M_DAY_csütörtök, péntek és szombat', 0, 0, 0, 1, 1, 1, 0, CAL_START, CAL_END,
		],

		[
			["csütörtök, péntek és vasárnap",],
			'M_DAY_csütörtök, péntek és vasárnap', 0, 0, 0, 1, 1, 0, 1, CAL_START, CAL_END,
		],

		[
			["csütörtök, péntek, szombat és vasárnap",],
			'M_DAY_csütörtök, péntek, szombat és vasárnap', 0, 0, 0, 1, 1, 1, 1, CAL_START, CAL_END,
		],

		[
			["csütörtök és szombat",],
			'M_DAY_csütörtök és szombat', 0, 0, 0, 1, 0, 1, 0, CAL_START, CAL_END,
		],

		[
			["csütörtök, szombat és vasárnap",],
			'M_DAY_csütörtök, szombat és vasárnap', 0, 0, 0, 1, 0, 1, 1, CAL_START, CAL_END,
		],

		[
			["csütörtök és vasárnap",],
			'M_DAY_csütörtök és vasárnap', 0, 0, 0, 1, 0, 0, 1, CAL_START, CAL_END,
		],

		[
			["csütörtök és vasárnap kivételével naponta",],
			'M_DAY_csütörtök és vasárnap kivételével naponta', 1, 1, 1, 0, 1, 1, 0, CAL_START, CAL_END,
		],

		[
			["péntek és szombat",],
			'M_DAY_péntek és szombat', 0, 0, 0, 0, 1, 1, 0, CAL_START, CAL_END,
		],

		[
			["péntek, szombat és vasárnap",
				"péntek és szombat és vasárnap",],
			'M_DAY_péntek és szombat és vasárnap', 0, 0, 0, 0, 1, 1, 1, CAL_START, CAL_END,
		],

		[
			["péntek és vasárnap",],
			'M_DAY_péntek és vasárnap', 0, 0, 0, 0, 1, 0, 1, CAL_START, CAL_END,
		],

		[
			["szombat és vasárnap",],
			'M_DAY_szombat és vasárnap', 0, 0, 0, 0, 0, 1, 1, CAL_START, CAL_END,
		],

		# Kivételével

		[
			["csütörtök kivételével",],
			'M_DAY_csütörtök kivételével', 1, 1, 1, 0, 1, 1, 1, CAL_START, CAL_END,
		],

		[
			["hétfő kivételével",
				"hétfő kivételével naponta", "hétfői napok kivételével",],
			'M_DAY_hétfő kivételével', 0, 1, 1, 1, 1, 1, 1, CAL_START, CAL_END,
		],

		[
			["kedd kivételével",],
			'M_DAY_kedd kivételével', 1, 0, 1, 1, 1, 1, 1, CAL_START, CAL_END,
		],

		[
			["péntek kivételével",],
			'M_DAY_péntek kivételével', 1, 1, 1, 1, 0, 1, 1, CAL_START, CAL_END,
		],

		[
			["szerda kivételével",],
			'M_DAY_szerda kivételével', 1, 1, 0, 1, 1, 1, 1, CAL_START, CAL_END,
		],

		[
			["szombat kivételével",],
			'M_DAY_szombat kivételével', 1, 1, 1, 1, 1, 0, 1, CAL_START, CAL_END,
		],

		[
			["vasárnap kivételével",
				"hétfőtől - szombatig",
				"hétfől szombatig",
				"hétfő - szombat",],
			'M_DAY_vasárnap kivételével', 1, 1, 1, 1, 1, 1, 0, CAL_START, CAL_END,
		],
	];
#>>>

	foreach my $i ( 1 .. $#$data ) {
		$data->[$i]->[ $#{ $data->[0] } + 1 ] = $data->[$i]->[0]->[0];    # service_desc
		$SERVICE_MAP->{$_} = $data->[$i]->[1] for @{ $data->[$i]->[0] };
		shift @{ $data->[$i] };

		HuGTFS::Cal->new( map { $data->[0]->[$_] => $data->[$i]->[$_] } 0 .. $#{ $data->[0] } );
	}

	foreach my $i ( 1 .. $#$day_only ) {
		$day_only->[$i]->[ $#{ $day_only->[0] } + 1 ]
			= $day_only->[$i]->[0]->[0];                                  # service_desc
		$SERVICE_MAP->{$_} = $day_only->[$i]->[1] for @{ $day_only->[$i]->[0] };
		shift @{ $day_only->[$i] };

		HuGTFS::Cal->new( map { $day_only->[0]->[$_] => $day_only->[$i]->[$_] }
				0 .. $#{ $day_only->[0] } );
	}

	my $exceptions = [ [qw/service_id date exception_type/], ];
# DATEMOD: Update yearly
#<<<

=pod
		### munkanapi =>
		### A+ B+ C- D- X+ +- 5- 6- 7-

		[qw/M_A DATE added  /],
		[qw/M_B DATE added  /],
		[qw/M_C DATE removed/],
		[qw/M_D DATE removed/],
		[qw/M_X DATE added  /],
		[qw/M_+ DATE removed/],
		[qw/M_4 DATE added  /],
		[qw/M_5 DATE removed/],
		[qw/M_6 DATE removed/],
		[qw/M_7 DATE removed/],
=cut

	push(
		@$exceptions,

		[qw/M_A 20121214 added  /],
		[qw/M_B 20121214 added  /],
		[qw/M_C 20121214 removed/],
		[qw/M_D 20121214 removed/],
		[qw/M_X 20121214 added  /],
		[qw/M_+ 20121214 removed/],
		[qw/M_4 20121214 added  /],
		[qw/M_5 20121214 removed/],
		[qw/M_6 20121214 removed/],
		[qw/M_7 20121214 removed/],

		[qw/M_A 20130823 added  /],
		[qw/M_B 20130823 added  /],
		[qw/M_C 20130823 removed/],
		[qw/M_D 20130823 removed/],
		[qw/M_X 20130823 added  /],
		[qw/M_+ 20130823 removed/],
		[qw/M_4 20130823 added  /],
		[qw/M_5 20130823 removed/],
		[qw/M_6 20130823 removed/],
		[qw/M_7 20130823 removed/],

		[qw/M_A 20131206 added  /],
		[qw/M_B 20131206 added  /],
		[qw/M_C 20131206 removed/],
		[qw/M_D 20131206 removed/],
		[qw/M_X 20131206 added  /],
		[qw/M_+ 20131206 removed/],
		[qw/M_4 20131206 added  /],
		[qw/M_5 20131206 removed/],
		[qw/M_6 20131206 removed/],
		[qw/M_7 20131206 removed/],
	);

=pod
		### pénteki =>
		### A+ B+ C- D- X+ +- 5+ 6- 7-

		[qw/M_A DATE added  /],
		[qw/M_B DATE added  /],
		[qw/M_C DATE removed/],
		[qw/M_D DATE removed/],
		[qw/M_X DATE added  /],
		[qw/M_+ DATE removed/],
		[qw/M_4 DATE removed/],
		[qw/M_5 DATE added  /],
		[qw/M_6 DATE removed/],
		[qw/M_7 DATE removed/],
=cut

	push(
		@$exceptions,

		[qw/M_A 20121215 added  /],
		[qw/M_B 20121215 added  /],
		[qw/M_C 20121215 removed/],
		[qw/M_D 20121215 removed/],
		[qw/M_X 20121215 added  /],
		[qw/M_+ 20121215 removed/],
		[qw/M_4 20121215 removed/],
		[qw/M_5 20121215 added  /],
		[qw/M_6 20121215 removed/],
		[qw/M_7 20121215 removed/],

		[qw/M_A 20130314 added  /],
		[qw/M_B 20130314 added  /],
		[qw/M_C 20130314 removed/],
		[qw/M_D 20130314 removed/],
		[qw/M_X 20130314 added  /],
		[qw/M_+ 20130314 removed/],
		[qw/M_4 20130314 removed/],
		[qw/M_5 20130314 added  /],
		[qw/M_6 20130314 removed/],
		[qw/M_7 20130314 removed/],

		[qw/M_A 20130824 added  /],
		[qw/M_B 20130824 added  /],
		[qw/M_C 20130824 removed/],
		[qw/M_D 20130824 removed/],
		[qw/M_X 20130824 added  /],
		[qw/M_+ 20130824 removed/],
		[qw/M_4 20130824 removed/],
		[qw/M_5 20130824 added  /],
		[qw/M_6 20130824 removed/],
		[qw/M_7 20130824 removed/],

		[qw/M_A 20131031 added  /],
		[qw/M_B 20131031 added  /],
		[qw/M_C 20131031 removed/],
		[qw/M_D 20131031 removed/],
		[qw/M_X 20131031 added  /],
		[qw/M_+ 20131031 removed/],
		[qw/M_4 20131031 removed/],
		[qw/M_5 20131031 added  /],
		[qw/M_6 20131031 removed/],
		[qw/M_7 20131031 removed/],

		[qw/M_A 20131207 added  /],
		[qw/M_B 20131207 added  /],
		[qw/M_C 20131207 removed/],
		[qw/M_D 20131207 removed/],
		[qw/M_X 20131207 added  /],
		[qw/M_+ 20131207 removed/],
		[qw/M_4 20131207 removed/],
		[qw/M_5 20131207 added  /],
		[qw/M_6 20131207 removed/],
		[qw/M_7 20131207 removed/],
	);

=pod
		### szombati =>
		### A- B- C+ D+ X+ +- 5- 6+ 7-

		[qw/M_A DATE removed/],
		[qw/M_B DATE removed/],
		[qw/M_C DATE added  /],
		[qw/M_D DATE added  /],
		[qw/M_X DATE added  /],
		[qw/M_+ DATE removed/],
		[qw/M_4 DATE removed/],
		[qw/M_5 DATE removed/],
		[qw/M_6 DATE added  /],
		[qw/M_7 DATE removed/],
=cut

	push(
		@$exceptions,

		[qw/M_A 20130315 removed/],
		[qw/M_B 20130315 removed/],
		[qw/M_C 20130315 added  /],
		[qw/M_D 20130315 added  /],
		[qw/M_X 20130315 added  /],
		[qw/M_+ 20130315 removed/],
		[qw/M_4 20130315 removed/],
		[qw/M_5 20130315 removed/],
		[qw/M_6 20130315 added  /],
		[qw/M_7 20130315 removed/],

		[qw/M_A 20131101 removed/],
		[qw/M_B 20131101 removed/],
		[qw/M_C 20131101 added  /],
		[qw/M_D 20131101 added  /],
		[qw/M_X 20131101 added  /],
		[qw/M_+ 20131101 removed/],
		[qw/M_4 20131101 removed/],
		[qw/M_5 20131101 removed/],
		[qw/M_6 20131101 added  /],
		[qw/M_7 20131101 removed/],
	);

=pod
		### vasárnapi =>
		### A- B+ C+ D- X- ++ 5- 6- 7+

		[qw/M_A DATE removed/],
		[qw/M_B DATE added  /],
		[qw/M_C DATE added  /],
		[qw/M_D DATE removed/],
		[qw/M_X DATE removed/],
		[qw/M_+ DATE added  /],
		[qw/M_4 DATE removed/],
		[qw/M_5 DATE removed/],
		[qw/M_6 DATE removed/],
		[qw/M_7 DATE added  /],
=cut

	push(
		@$exceptions,

		[qw/M_A 20121226 removed/],
		[qw/M_B 20121226 added  /],
		[qw/M_C 20121226 added  /],
		[qw/M_D 20121226 removed/],
		[qw/M_X 20121226 removed/],
		[qw/M_+ 20121226 added  /],
		[qw/M_4 20121226 removed/],
		[qw/M_5 20121226 removed/],
		[qw/M_6 20121226 removed/],
		[qw/M_7 20121226 added  /],

		[qw/M_A 20130101 removed/],
		[qw/M_B 20130101 added  /],
		[qw/M_C 20130101 added  /],
		[qw/M_D 20130101 removed/],
		[qw/M_X 20130101 removed/],
		[qw/M_+ 20130101 added  /],
		[qw/M_4 20130101 removed/],
		[qw/M_5 20130101 removed/],
		[qw/M_6 20130101 removed/],
		[qw/M_7 20130101 added  /],

		[qw/M_A 20130401 removed/],
		[qw/M_B 20130401 added  /],
		[qw/M_C 20130401 added  /],
		[qw/M_D 20130401 removed/],
		[qw/M_X 20130401 removed/],
		[qw/M_+ 20130401 added  /],
		[qw/M_4 20130401 removed/],
		[qw/M_5 20130401 removed/],
		[qw/M_6 20130401 removed/],
		[qw/M_7 20130401 added  /],

		[qw/M_A 20130520 removed/],
		[qw/M_B 20130520 added  /],
		[qw/M_C 20130520 added  /],
		[qw/M_D 20130520 removed/],
		[qw/M_X 20130520 removed/],
		[qw/M_+ 20130520 added  /],
		[qw/M_4 20130520 removed/],
		[qw/M_5 20130520 removed/],
		[qw/M_6 20130520 removed/],
		[qw/M_7 20130520 added  /],

		[qw/M_A 20130820 removed/],
		[qw/M_B 20130820 added  /],
		[qw/M_C 20130820 added  /],
		[qw/M_D 20130820 removed/],
		[qw/M_X 20130820 removed/],
		[qw/M_+ 20130820 added  /],
		[qw/M_4 20130820 removed/],
		[qw/M_5 20130820 removed/],
		[qw/M_6 20130820 removed/],
		[qw/M_7 20130820 added  /],
	);

=pod
		### ünnepnapi =>
		### A- B- C+ D+ X- ++ 5- 6- 7-

		[qw/M_A DATE removed/],
		[qw/M_B DATE removed/],
		[qw/M_C DATE added  /],
		[qw/M_D DATE added  /],
		[qw/M_X DATE removed/],
		[qw/M_+ DATE added  /],
		[qw/M_4 DATE removed/],
		[qw/M_5 DATE removed/],
		[qw/M_6 DATE removed/],
		[qw/M_7 DATE removed/],
		[qw/M_U DATE added  /],
=cut

	push(
		@$exceptions,

		[qw/M_A 20121224 removed/],
		[qw/M_B 20121224 removed/],
		[qw/M_C 20121224 added  /],
		[qw/M_D 20121224 added  /],
		[qw/M_X 20121224 removed/],
		[qw/M_+ 20121224 added  /],
		[qw/M_4 20121224 removed/],
		[qw/M_5 20121224 removed/],
		[qw/M_6 20121224 removed/],
		[qw/M_7 20121224 removed/],
		[qw/M_U 20121224 added  /],

		[qw/M_A 20121225 removed/],
		[qw/M_B 20121225 removed/],
		[qw/M_C 20121225 added  /],
		[qw/M_D 20121225 added  /],
		[qw/M_X 20121225 removed/],
		[qw/M_+ 20121225 added  /],
		[qw/M_4 20121225 removed/],
		[qw/M_5 20121225 removed/],
		[qw/M_6 20121225 removed/],
		[qw/M_7 20121225 removed/],
		[qw/M_U 20121225 added  /],

		[qw/M_A 20121223 removed/],
		[qw/M_B 20121223 removed/],
		[qw/M_C 20121223 added  /],
		[qw/M_D 20121223 added  /],
		[qw/M_X 20121223 removed/],
		[qw/M_+ 20121223 added  /],
		[qw/M_4 20121223 removed/],
		[qw/M_5 20121223 removed/],
		[qw/M_6 20121223 removed/],
		[qw/M_7 20121223 removed/],
		[qw/M_U 20121223 added  /],

		[qw/M_A 20121230 removed/],
		[qw/M_B 20121230 removed/],
		[qw/M_C 20121230 added  /],
		[qw/M_D 20121230 added  /],
		[qw/M_X 20121230 removed/],
		[qw/M_+ 20121230 added  /],
		[qw/M_4 20121230 removed/],
		[qw/M_5 20121230 removed/],
		[qw/M_6 20121230 removed/],
		[qw/M_7 20121230 removed/],
		[qw/M_U 20121230 added  /],

		[qw/M_A 20121231 removed/],
		[qw/M_B 20121231 removed/],
		[qw/M_C 20121231 added  /],
		[qw/M_D 20121231 added  /],
		[qw/M_X 20121231 removed/],
		[qw/M_+ 20121231 added  /],
		[qw/M_4 20121231 removed/],
		[qw/M_5 20121231 removed/],
		[qw/M_6 20121231 removed/],
		[qw/M_7 20121231 removed/],
		[qw/M_U 20121231 added  /],

		[qw/M_A 20130316 removed/],
		[qw/M_B 20130316 removed/],
		[qw/M_C 20130316 added  /],
		[qw/M_D 20130316 added  /],
		[qw/M_X 20130316 removed/],
		[qw/M_+ 20130316 added  /],
		[qw/M_4 20130316 removed/],
		[qw/M_5 20130316 removed/],
		[qw/M_6 20130316 removed/],
		[qw/M_7 20130316 removed/],
		[qw/M_U 20130316 added  /],

		[qw/M_A 20130331 removed/],
		[qw/M_B 20130331 removed/],
		[qw/M_C 20130331 added  /],
		[qw/M_D 20130331 added  /],
		[qw/M_X 20130331 removed/],
		[qw/M_+ 20130331 added  /],
		[qw/M_4 20130331 removed/],
		[qw/M_5 20130331 removed/],
		[qw/M_6 20130331 removed/],
		[qw/M_7 20130331 removed/],
		[qw/M_U 20130331 added  /],

		[qw/M_A 20130501 removed/],
		[qw/M_B 20130501 removed/],
		[qw/M_C 20130501 added  /],
		[qw/M_D 20130501 added  /],
		[qw/M_X 20130501 removed/],
		[qw/M_+ 20130501 added  /],
		[qw/M_4 20130501 removed/],
		[qw/M_5 20130501 removed/],
		[qw/M_6 20130501 removed/],
		[qw/M_7 20130501 removed/],
		[qw/M_U 20130501 added  /],

		[qw/M_A 20130519 removed/],
		[qw/M_B 20130519 removed/],
		[qw/M_C 20130519 added  /],
		[qw/M_D 20130519 added  /],
		[qw/M_X 20130519 removed/],
		[qw/M_+ 20130519 added  /],
		[qw/M_4 20130519 removed/],
		[qw/M_5 20130519 removed/],
		[qw/M_6 20130519 removed/],
		[qw/M_7 20130519 removed/],
		[qw/M_U 20130519 added  /],

		[qw/M_A 20130818 removed/],
		[qw/M_B 20130818 removed/],
		[qw/M_C 20130818 added  /],
		[qw/M_D 20130818 added  /],
		[qw/M_X 20130818 removed/],
		[qw/M_+ 20130818 added  /],
		[qw/M_4 20130818 removed/],
		[qw/M_5 20130818 removed/],
		[qw/M_6 20130818 removed/],
		[qw/M_7 20130818 removed/],
		[qw/M_U 20130818 added  /],

		[qw/M_A 20130819 removed/],
		[qw/M_B 20130819 removed/],
		[qw/M_C 20130819 added  /],
		[qw/M_D 20130819 added  /],
		[qw/M_X 20130819 removed/],
		[qw/M_+ 20130819 added  /],
		[qw/M_4 20130819 removed/],
		[qw/M_5 20130819 removed/],
		[qw/M_6 20130819 removed/],
		[qw/M_7 20130819 removed/],
		[qw/M_U 20130819 added  /],

		[qw/M_A 20131023 removed/],
		[qw/M_B 20131023 removed/],
		[qw/M_C 20131023 added  /],
		[qw/M_D 20131023 added  /],
		[qw/M_X 20131023 removed/],
		[qw/M_+ 20131023 added  /],
		[qw/M_4 20131023 removed/],
		[qw/M_5 20131023 removed/],
		[qw/M_6 20131023 removed/],
		[qw/M_7 20131023 removed/],
		[qw/M_U 20131023 added  /],

		[qw/M_A 20131102 removed/],
		[qw/M_B 20131102 removed/],
		[qw/M_C 20131102 added  /],
		[qw/M_D 20131102 added  /],
		[qw/M_X 20131102 removed/],
		[qw/M_+ 20131102 added  /],
		[qw/M_4 20131102 removed/],
		[qw/M_5 20131102 removed/],
		[qw/M_6 20131102 removed/],
		[qw/M_7 20131102 removed/],
		[qw/M_U 20131102 added  /],
	);

#>>>

	foreach my $i ( 1 .. $#$exceptions ) {
		HuGTFS::Cal->find( $exceptions->[$i]->[0] )
			->add_exception( @{ $exceptions->[$i] }[ 1, 2 ] );
	}

	### COMBINE EXCEPTIONS
	foreach my $combined (
#<<<
		[ [ 'M_C', 'M_5' ] => 'M_MC_M5' ],
		[ [ 'M_4', 'M_7' ] => 'M_M4_M7' ],
		[ [ 'M_5', 'M_7' ] => 'M_M5_M7' ],
		[ [ 'M_6', 'M_7' ] => 'M_M6_M7' ],
		[ [ 'M_4', 'M_U' ] => 'M_M4_MU' ],
	) {
#>>>
		# HuGTFS::Cal::or_service( @{ $combined->[0] } => $combined->[1] );

		my $combined_service = HuGTFS::Cal->find( $combined->[1] );

		# Copies exceptions, with 'add' ones being prefered over 'remove'
		foreach my $service_id ( @{ $combined->[0] } ) {
			my $service = HuGTFS::Cal->find($service_id);
			foreach my $year ( keys %{ $service->{exceptions} } ) {
				foreach my $month ( keys %{ $service->{exceptions}->{$year} } ) {
					foreach my $day ( keys %{ $service->{exceptions}->{$year}->{$month} } ) {
						my $date = DateTime->new(
							year  => $year,
							month => $month,
							day   => $day
						);

						if ( $service->{exceptions}->{$year}->{$month}->{$day} eq 'added' ) {
							$combined_service->add_exception( $date, 'added' );
						}
						elsif (
							!$combined_service->{exceptions}->{ $date->year }->{ $date->month }
							->{ $date->day } )
						{
							$combined_service->add_exception( $date, 'removed' );
						}
					}
				}
			}
		}
	}

=pod
	### Remove
	foreach my $not (
#<<<
		[ ['M_5', 'M_6', 'M_U' ] => 'M_M4_M7' ],
		[ ['M_5', 'M_6', 'M_7' ] => 'M_M4_MU' ],
	) {
#>>>
		my $removee = HuGTFS::Cal->find($not->[1]);

		foreach my $service_id ( @{ $not->[0] } ) {
			my $service = HuGTFS::Cal->find($service_id);

			$removee->remove($service);
		}
	}
=cut

	### ANTIED
	foreach my $antied (
#<<<
		[ 'M_5'             => 'M_25'                ],
		[ 'M_6'             => 'M_26'                ],
		[ 'M_7'             => 'M_27'                ],
		[ 'M_A'             => 'M_NOT_A'             ],
		[ 'M_B'             => 'M_NOT_B'             ],
		[ 'M_M4_M7'         => 'M_NOT_M4_M7'         ],
		[ 'M_M5_M7'         => 'M_NOT_M5_M7'         ],
	) {
#>>>

		# HuGTFS::Cal::subtract_service('DAILY', $antied->[0] => $antied->[1]);

		my $service      = HuGTFS::Cal->find( $antied->[0] );
		my $anti_service = HuGTFS::Cal->find( $antied->[1] );

		# Only reverses exceptions, the days of operation should be set correctly above
		foreach my $year ( keys %{ $service->{exceptions} } ) {
			foreach my $month ( keys %{ $service->{exceptions}->{$year} } ) {
				foreach my $day ( keys %{ $service->{exceptions}->{$year}->{$month} } ) {
					my $date = DateTime->new(
						year  => $year,
						month => $month,
						day   => $day
					);

					$anti_service->add_exception( $date,
						$service->get_exception($date) eq 'added'
						? 'removed'
						: 'added' )

				}
			}
		}
	}
}

sub run_interval($$)
{
	my ( $from, $to ) = @_;
	my $f_date = DateTime->new(
		year  => $from->[0],
		month => $from->[1],
		day   => $from->[2]
	);
	my $t_date = DateTime->new(
		year  => $to->[0],
		month => $to->[1],
		day   => $to->[2]
	);

	my @days;

	while ( $f_date->ymd('') <= $t_date->ymd('') ) {
		push @days, [ $f_date->year, _0 $f_date->month, _0 $f_date->day ];
		$f_date->add( days => 1 );
	}

	return @days;
}

sub negate_dates
{
	my @interval = @_;
	my @negated  = ();
	my $start    = [ CAL_START =~ m/(\d{4})(\d\d)(\d\d)/ ];
	my $end      = [ CAL_END =~ m/(\d{4})(\d\d)(\d\d)/ ];
	my $wherein  = 0;

	my $f_date = DateTime->new(
		year  => $start->[0],
		month => $start->[1],
		day   => $start->[2]
	);

	while (
		$f_date->year < $end->[0]
		|| (
			$f_date->year == $end->[0]
			&& (   ( $f_date->month == $end->[1] && $f_date->day <= $end->[2] )
				|| ( $f_date->month < $end->[1] ) )
		)
		)
	{
		if (
			$wherein <= $#interval
			&& !(
				   defined $interval[$wherein]
				&& defined $interval[$wherein]->[0]
				&& defined $interval[$wherein]->[1]
				&& defined $interval[$wherein]->[2]
			)
			)
		{
			confess "Life sucks: $wherein: " . Dumper( \@interval );
		}
		if (   $wherein <= $#interval
			&& $f_date->year == $interval[$wherein]->[0]
			&& $f_date->month == $interval[$wherein]->[1]
			&& $f_date->day == $interval[$wherein]->[2] )
		{
			$wherein++;
		}
		else {
			push @negated, [ $f_date->year, _0 $f_date->month, _0 $f_date->day ];
		}
		$f_date->add( days => 1 );
	}

	return @negated;
}

sub parse_dates
{
	my ( $text, $die_alone, $reset ) = @_;
	$text =~ s/ (?:és|valamint) //g;
	$text =~ s/(\d)-én/$1/g;
	$text =~ s/\s+//g;
	my @days          = ();
	my $dash_interval = 0;

	state $year  = 0;
	state $month = 0;
	my $day = 0;
	my $interval;

	if ($reset) {
		( $year, $month ) = ( 0, 0 );
	}

	while ($text) {

		# 2010.XI.***
		if ( $text =~ m/^(\d{4})\.([XIV]+)\.(.*)$/ ) {
			$year  = $1;
			$month = $R_MONTH{$2};
			$text  = $3;
		}

		# 2010.12.***
		elsif ( $text =~ m/^(\d{4})\.(\d{2})\.(.*)$/ ) {
			$year  = $1;
			$month = $2;
			$text  = $3;
		}

		# XI.***
		elsif ( $text =~ m/^([XIV]+)\.(.*)$/ ) {
			$month = $R_MONTH{$1};
			$text  = $2;
		}

		# 05.12-ig***
		elsif ( $text =~ m/^(\d{2})\.(\d{2})-ig,?(.*)$/ ) {
			$month = $1;
			$day   = $2;
			$text  = $3;

			# no start for interval, assume CAL_START
			unless ($interval) {
				$interval = [ CAL_START =~ m/^(\d{4})(\d{2})(\d{2})$/ ];
			}

			push @days, run_interval $interval, [ $year, $month, $day ];
			undef $interval;
		}

		# 12-ig***
		elsif ( $text =~ m/^(\d{2})-ig,?(.*)$/ ) {
			$day  = $1;
			$text = $2;

			# no start for interval, assume CAL_START
			unless ($interval) {
				$interval = [ CAL_START =~ m/^(\d{4})(\d{2})(\d{2})$/ ];
			}

			push @days, run_interval $interval, [ $year, $month, $day ];
			undef $interval;
		}

		# 05.12-től***
		elsif ( $text =~ m/^(\d{2})\.(\d{2})-(?:-t[őó]l)?,?(.*)$/ ) {
			$month = $1;
			$day   = $2;
			$text  = $3;

			$interval = [ $year, $month, $day ];
		}

		# 12-től***
		elsif ( $text =~ m/^(\d{2})-(?:t[óő]l)?,?(.*)$/ ) {
			$day  = $1;
			$text = $2;

			$interval = [ $year, $month, $day ];
		}

		# 31***
		elsif ( $text =~ m/^(\d{2})[.,]*(.*)$/ ) {
			$day  = $1;
			$text = $2;
			push @days, [ $year, $month, $day ];
		}

		# -***
		elsif ( $text =~ m/^-(.*)$/ ) {
			$text          = $2;
			$dash_interval = 2;
			$interval      = [ $year, $month, $day ];
		}
		else {
			$die_alone ? die "Can't parse dates: <<$text>>" : $log->warn("Unknown: $text");
			return wantarray ? () : undef;
		}

		if ( $dash_interval == 1 ) {
			push @days, run_interval $interval, [ $year, $month, $day ];
			$interval      = undef;
			$dash_interval = 0;
		}

		$dash_interval = 1 if ( $dash_interval == 2 );
	}

	if ($interval) {
		push @days, run_interval $interval, [ CAL_END =~ m/(\d{4})(\d\d)(\d\d)/ ];
	}

	return @days;
}

sub create_service_from_text
{
	my $text              = shift;
	my @remove_exceptions = @_;
	state $service_counter = 1;

	return undef if length $text > 250;

	$text = service_remap( $text );

	my $service_data = {
		id       => "M_SC_$service_counter",
		add      => [],                        # days
		remove   => [@remove_exceptions],      # days
		services => [],                        # [id, days to use service]
		descr    => $text,
	};

	my @service_names = sort { length $b <=> length $a } keys %$SERVICE_MAP;
	my $PRE_regexp_service = ( join '|', @service_names );
	$PRE_regexp_service =~ s/([.()])/\\$1/g;
	state $regexp_service = qr/(?:$PRE_regexp_service)/o;

	state $regexp_num   = qr/(?:\d{4}\.)?(?:(?:[IVX]+|\d{2})\.)?\d{2}/;
	state $regexp_day   = qr/\b(?:$regexp_num\b|$regexp_num\.(?=\W))/;
	state $regexp_from  = qr/\b$regexp_num(?:-t[óő]l| -)\b/;
	state $regexp_to    = qr/\b$regexp_num-ig\b/;
	state $regexp_comma = qr/,?\s*/;
	state $regexp_interval
		= qr/(?:(?:$regexp_to|$regexp_from|$regexp_to és $regexp_from|$regexp_to, valamint $regexp_from|$regexp_from $regexp_to)\s*)+/;
	state $regexp_anydate = qr/(?:(?:$regexp_interval|$regexp_day)$regexp_comma)+/;
	state $regexp_c_e     = qr/(?:\z|\s*,\s*|\s+)/;

	if ( $PARSED_SERVICE_MAP->{$text} && !scalar @remove_exceptions ) {
		return $PARSED_SERVICE_MAP->{$text};
	}
	if ( $SERVICE_MAP->{$text} && !scalar @remove_exceptions ) {
		return $SERVICE_MAP->{$text};
	}

	# Cleanup
	$text =~ s/ \./ /go;
	$text =~ s/\. ,/.,/go;
	$text =~ s/\b([1-9])\b/0$1/go;
	$text =~ s/\b([XIV]+\.) (\d{2})\b/$1$2/go;

	# DATEMOD
	$text =~ s/ I X/ IX/go;
	$text =~ s/de nem közlekedik :/de nem közlekedik: /go;
	$text =~ s/(?:és|de) nem (?:közl|közlekedik):?\s*($regexp_anydate)$regexp_c_e(?:és|de) nem (?:közl|közlekedik):?\s*($regexp_anydate)$/de nem közlekedik: $1, $2/go;

	# Cleanup
	$text =~ s/,,+/,/go;

	if($text =~ m/^nem közlekedik: $regexp_anydate$/o) {
		$text = "naponta, de $text";
	}

	parse_dates( '', 0, 1 );    # reset dates

	while ($text) {
		# közlekedik <anydate>
		if ( $text =~ m/^közlekedik:? (?<dates>$regexp_anydate)$/p ) {
			my @d = parse_dates( $+{dates} );
			return undef unless scalar @d;
			push @{ $service_data->{add} }, @d;

			$text = ${^POSTMATCH};
			next;
		}

		# (és|valamint) <days>
		if ( $text =~ m/^(?:és|valamint) (?<dates>$regexp_anydate)(?:${regexp_comma}valamint (?<secondary_dates>$regexp_anydate))?$/p ) {
			my @d = parse_dates( $+{dates} );
			return undef unless scalar @d;
			push @{ $service_data->{add} }, @d;

			if($+{secondary_dates}) {
				@d = parse_dates( $+{secondary_dates} );
				return undef unless scalar @d;
				push @{ $service_data->{add} }, @d;
			}

			$text = ${^POSTMATCH};
			next;
		}

		# de? nem közlekedik: <days>
		if ( $text =~ m/^(?:de )?nem (?:közl\.?|közlekedik):?\s*(?<dates>$regexp_anydate)$/p ) {
			my @d = parse_dates( $+{dates} );
			return undef unless scalar @d;
			push @{ $service_data->{remove} }, @d;

			$text = ${^POSTMATCH};
			next;
		}

		# (és|valamint) <days> de nem közlekedik: <days>
		if ( $text =~ m/^(?:és|valamint) (?<date_add>$regexp_anydate)(?:de )?nem (?:közl\.?|közlekedik):?\s*(?<date_remove>$regexp_anydate)$/p ) {
			my @d = parse_dates( $+{date_add} );
			return undef unless scalar @d;
			push @{ $service_data->{add} }, @d;

			@d = parse_dates( $+{date_remove} );
			return undef unless scalar @d;
			push @{ $service_data->{remove} }, @d;

			$text = ${^POSTMATCH};
			next;
		}

		# <day> <service>
		if ( $text =~ m/^(?<day>$regexp_day)\s+$regexp_service$regexp_c_e/p ) {
			my @d = parse_dates( $+{day} );
			return undef unless scalar @d;
			push @{ $service_data->{add} }, @d;

			$text = ${^POSTMATCH};
			next;
		}

		# és? <day>
		if ( $text =~ m/^(?:és\s+)?(?<day>$regexp_day)$regexp_comma$regexp_c_e/p ) {
			my @d = parse_dates( $+{day} );
			return undef unless scalar @d;
			push @{ $service_data->{add} }, @d;

			$text = ${^POSTMATCH};
			next;
		}

=pod
		# valamint? <day interval> <day interval>? <service>
		if ( $text
			=~ m/^(?:valamint\s*)?(?<interval_add>$regexp_interval),\s+(?:(?:és|valamint)?\s*(?<interval>$regexp_interval))\s+(?<service>$regexp_service)$regexp_c_e/p
			)
		{
			# interval
			{
				my @d = parse_dates( $+{interval_add} );
				return undef unless scalar @d;
				push @{ $service_data->{add} }, @d;
			}

			# interval + service
			my $data = [ $SERVICE_MAP->{ $+{service} } ];
			if ( $+{interval} ) {
				my @d = parse_dates( $+{interval} );
				return undef unless scalar @d;
				push @$data, @d;
			}
			else {
				push @$data,
					run_interval(
					[ CAL_START =~ m/^(\d{4})(\d{2})(\d{2})$/ ],
					[ CAL_END   =~ m/^(\d{4})(\d{2})(\d{2})$/ ]
					);
			}
			push @{ $service_data->{services} }, $data;

			$text = ${^POSTMATCH};
			next;
		}
=cut

		# valamint? <day interval> <day interval> <service>
		if ( $text
			=~ m/^(?:valamint\s*)?(?<interval1>$regexp_interval), (?:és |valamint )?(?<interval2>$regexp_interval)\s+(?<service>$regexp_service)$regexp_c_e/p
			)
		{
			# interval + service
			my $data = [ $SERVICE_MAP->{ $+{service} } ];

			my @d = parse_dates( $+{interval1} );
			return undef unless scalar @d;
			push @$data, @d;

			@d = parse_dates( $+{interval2} );
			return undef unless scalar @d;
			push @$data, @d;

			push @{ $service_data->{services} }, $data;

			$text = ${^POSTMATCH};
			next;
		}

		# (valamint|közlekedik)? <day interval>? <service>
		if ( $text
			=~ m/^(?:(?:valamint|közlekedik)\s+)?(?:(?<interval>$regexp_interval)\s+)?(?<service>$regexp_service)$regexp_c_e(?!$regexp_service)/p
			)
		{
			my $data = [ $SERVICE_MAP->{ $+{service} } ];
			if ( $+{interval} ) {
				my @d = parse_dates( $+{interval} );
				return undef unless scalar @d;
				push @$data, @d;
			}
			else {
				push @$data,
					run_interval(
					[ CAL_START =~ m/^(\d{4})(\d{2})(\d{2})$/ ],
					[ CAL_END   =~ m/^(\d{4})(\d{2})(\d{2})$/ ]
					);
			}
			push @{ $service_data->{services} }, $data;

			$text = ${^POSTMATCH};
			next;
		}

		#$log->warn("Failed parsing: $text");
		return undef;
	}

	# Create service id
	if ( !scalar @{ $service_data->{services} } && !scalar @{ $service_data->{add} } ) {
		return undef;
	}

	#die Dumper( $service_data );

	my $self = HuGTFS::Cal->new(
		start_date   => CAL_START,
		end_date     => CAL_END,
		service_id   => $service_data->{id},
		service_desc => $service_data->{descr},
	);
	for my $service ( @{ $service_data->{services} } ) {
		my $cal = HuGTFS::Cal->find( shift @$service );
		for (@$service) {
			my ($self_enabled, $cal_enabled) = ($self->enabled($_), $cal->enabled($_));
			next if ($self_enabled && $cal_enabled) || (!$self_enabled && !$cal_enabled);

			if($self_enabled) {
				$self->remove_exception( $_ );
			} else {
				$self->add_exception( $_, 'added' )
			}
		}
	}

	# Existing exceptions are removed to avoid needless exceptions.
	# ie. If the service is disabled w/o the exception, why keep it?
	for ( @{ $service_data->{add} } ) {
		$self->remove_exception($_);
		$self->add_exception( $_, 'added' )
			unless $self->enabled($_);
	}
	for ( @{ $service_data->{remove} } ) {
		$self->remove_exception($_);
		$self->add_exception( $_, 'removed' )
			if $self->enabled($_);
	}

	$self->start_date($self->min_date);
	$self->end_date($self->max_date);

	if ( !scalar @remove_exceptions ) {
		$PARSED_SERVICE_MAP->{ $service_data->{descr} } = $service_data->{id};
	}

	$service_counter++;
	return $service_data->{id};
}

sub service_remap
{
	# DATEMOD
	state $unparseable = {
		"péntek és szombat, és 2012.XII.23-tól 25-ig, 2012.XII.30-tól 31, valamint 2013.III.28, 31, V.08, 19, X.02"
			=> "péntek és szombat, és 2012.XII.23-tól 25-ig, 2012.XII.30-tól 31-ig, valamint 2013.III.28, 31, V.08, 19, X.02",
		"vasárnap és ünnepnap, de nem közlekedik 2013.VIII.19-től 20-ig2012.XII.30, 2013.V.09, 30, VIII.15, X.26, XI.01, de nem közl: 2012.XII.24, 31, 2013.III.16, X.23, XI.02"
			=> "vasárnap és ünnepnap, de nem közlekedik 2013.VIII.19-től 20-ig 2012.XII.30, 2013.V.09, 30, VIII.15, X.26, XI.01, de nem közl: 2012.XII.24, 31, 2013.III.16, X.23, XI.02",
		"munkanap és vasárnap közlekedési rend szerint2013.V.01, de nem közl: 2013.X.23"
			=> "munkanap és vasárnap közlekedési rend szerint 2013.V.01, de nem közl: 2013.X.23",
		"2012.XII.23-tól 26-ig, valamint 2012.XII.31" => "2012.XII.23-tól 26-ig naponta és 2012.XII.31",
		"2012.XII.26-ig és 2012.XII.29-től szombat, vasárnap és ünnepnapi közlekedési rend szerint, valamint 2012.XII.27.-én, 28-án"
			=> "2012.XII.26-ig és 2012.XII.29-től szombat, vasárnap és ünnepnapi közlekedési rend szerint, valamint 2012.XII.27, 28",
		"Közlekedik naponta, 2013.V.04-től VIII.31-ig szombati közlekedési rend szerint kivételével naponta"
			=> "naponta, 2013.V.04-től VIII.31-ig szombati közlekedési rend szerint kivételével naponta",
		"2013.V.13-ig és 2013.VIII.26-tól naponta, de nem közlekedik 2013.V.03-tól VI.07-ig pénteki közlekedési rend szerint"
			=> "2013.V.13-ig és 2013.VIII.26-tól naponta, 2013.V.03-tól VI.07-ig Nem közlekedik: pénteki közlekedési rend szerint",
		"2013.VI.16-tól IX.15-ig vasárnap (Magyarországi közlekedése: hétfő)"
			=> "2013.VI.16-tól IX.15-ig vasárnap",
		"2013.VI.15-től IX.15-ig szerda és szombat (Magyarországi közlekedése: csütörtök és vasárnap)"
			=> "2013.VI.15-től IX.15-ig szerda és szombat",
		"2012.XII.23-ig 2013.I.01-től V.19-ig VI.23-tól vasárnapi közlekedési rend szerint2012.XII.24, 26, de nem közl: 2012.XII.25"
			=> "2012.XII.23-ig 2013.I.01-től V.19-ig VI.23-tól vasárnapi közlekedési rend szerint 2012.XII.24, 26, de nem közl: 2012.XII.25"
	};

	my $service_text = shift;
	return $unparseable->{$service_text} || $service_text;
}

1 + 1 == 2;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut

__DATA__

sub create_fares {
	my @fares = (
	);

	$AGENCY->{fares} = [@fares];

	# http://www.mav-start.hu/utazas/tarifa_20090201.php?mid=14b5a3e658c8d3&chapter=12

	# IC helyjegy: 140

	# IC pótjegy: 400
	# Kedvezményes IC pótjegy: 220

	# IC pótjegy + helyjegy: 540
	# Kedvezményes IC pótjegy + helyjegy: 360

	# Map routes based on price

	for (qw/M_BELFOLDI_GYORS /) {
		M_BELFOLDI_GYORS
		M_EXPRESSZ
		M_INTERREGIO
		M_NEMZETKOZI_SZEMELY
		M_REGIONALIS
		M_SEBES
		M_SZEMELY
		M_VP

		M_NEMZETKOZI_GYORS
		M_ICVP
		M_INTERCITY
		M_RAILJET
		M_EUREGIO
		M_EUROCITY
		M_EURONIGHT
	}
}

1 + 1 == 2;
