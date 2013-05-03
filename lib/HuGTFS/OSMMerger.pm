
=head1 NAME

HuGTFS::OSMMerger - GTFS timetable + OSM geographic data merger

=head1 SYNOPSIS

	use HuGTFS::OSMMerger;

	my $osm_data = HuGTFS::OSMMerger->parse_osm( "BKV", $osm_file );
	my $gtfs_data = { routes => $ROUTES, stops => {} };

	# When merging gtfs data in one batch

	my $data = HuGTFS::OSMMerger->new(
		{
			remove_geometryless => 1,
			stop_is_match       => \&stop_is_match,
			create_stop         => \&create_stop
		},
		$osm_data,
		$gtfs_data,
	);

	# When merging gtfs data in multiple batches

	my $merger = HuGTFS::OSMMerger->new(
		{
			remove_geometryless => 1,
			stop_is_match       => \&stop_is_match,
			create_stop         => \&create_stop
		}
	);

	$merger->merge($gtfs_data);
	# $merger->{routes} contains the current batch of routes/trips, which
	# is cleared by the next call to merge
	# $merger->{stops} is NOT cleared between subsequent calls

=head1 REQUIRES

perl 5.14.0, XXX

=head1 EXPORTS

Nothing.

=head1 DESCRIPTION

=head1 METHODS

=cut

package HuGTFS::OSMMerger;

use 5.14.0;
use utf8;
use strict;
use warnings qw/ all /;

use Digest::MD5 qw(md5_hex);
use DateTime;
use Encode qw(encode_utf8);
use Geo::OSM::OsmReaderV6;
use Unicode::Normalize;
use Digest::SHA qw(sha256_hex);
use Log::Log4perl;
use HuGTFS::Util qw(:utils);
use Geo::Distance;

=head2 parse_osm $operator, $osm_file, $options

Extracts useful data from an osm file.

Returns:
	{
	  lines    => { $type => [line_variants] },
	  stops    => { id => {ref, name, alt_name, old_name, alt_old_name, old_alt_name, stop_lat, stop_lon },
	  pathways => { ... },
	}

TODO: Handle pathways, generating the appropriate data.

=cut

my $log = Log::Log4perl::get_logger(__PACKAGE__);
our $LS_REL = undef;

sub parse_osm
{

	# operator=[...], network=[...]
	# return { lines => { ' ' => [line_variants] }, pathways => { ... }, stops => { .. } }

	my ( $class, $operator, $osm_file, $options ) = (@_);
	my ( $lines, $line_variants, $line_segments, $sites ) = ( {}, {}, {}, {} );
	my ( $stops, $pathways, $shapes )    = ( {}, {}, {} );
	my ( $nodes, $ways,     $relations ) = ( {}, {}, {} );

	my $line_map = {
		bus       => {},
		tram      => {},
		funicular => {},
		ferry     => {},
		subway    => {},
		rail      => {},
	};

	$operator = qr/\b$operator(?:\b|\z|;)/ unless ref $operator;

	my $pr_first = sub {
		my $e = shift;

		if (
			(
				( $e->tag("highway") && $e->tag("highway") eq 'bus_stop' )
				|| (   $e->tag("railway")
					&& $e->tag("railway") =~ m/^(?:halt|station|tram_stop)$/ )
			)
			&& $e->tag("operator")
			&& $e->tag("operator") =~ $operator
			)
		{
			$nodes->{ $e->id } = $e;
			$e->add_tag( "create-stop", 1 );
		}

		$ways->{ $e->id } = $e
			if $e->isa("Geo::OSM::Way");

		if (   $e->isa("Geo::OSM::Relation")
			&& $e->tag("type")
			&& $e->tag("type") =~ m/^(?:route_master|route|public_transport|multipolygon)$/ )
		{
			$relations->{ $e->id } = $e;

			given ( $e->tag('type') ) {
				when ("route_segment") {
					$line_segments->{ $e->id } = handle_line_segment($e);
				}
				when ("route_master") {
					$lines->{ $e->id } = $e
						if $e->tag("operator") && $e->tag("operator") =~ $operator;
				}
				when ("route") {
					$line_variants->{ $e->id } = $e;
				}
				when ("public_transport") {
					if ( !$e->tag("operator") || $e->tag("operator") =~ $operator ) {
						$sites->{ $e->id } = $e;
						$e->add_tag( "create-stop", 1 );
					}
				}
			}
		}
	};

	my $pr_second = sub {
		my $e = shift;

		$nodes->{ $e->id } = $e
			if $e->isa("Geo::OSM::Node") && $nodes->{ $e->id } && !ref $nodes->{ $e->id };
	};

	$log->info("Reading osm data (stage one): $osm_file");

	unless ( Geo::OSM::OsmReader->init($pr_first)->load($osm_file) ) {
		$log->logdie("Failed to parse osm file: $osm_file");
	}

	# Purge unneded data
	{
		my $needed_variants      = {};
		my $needed_sites         = {};
		my $needed_multipolygons = {};

		foreach my $r ( values %$lines ) {
			$needed_variants->{ $_->ref } = 1 for $r->members;
		}

		foreach my $v ( keys %$needed_variants ) {
			foreach my $m ( $line_variants->{$v}->members ) {
				$needed_multipolygons->{ $m->ref } = 1
					if $m->member_type eq 'relation'
						&& $relations->{ $m->ref }
						&& $relations->{ $m->ref }->tag("type") eq 'multipolygon';

				$needed_sites->{ $m->ref } = 1
					if $m->member_type eq 'relation'
						&& $relations->{ $m->ref }
						&& $relations->{ $m->ref }->tag("type") eq 'public_transport';
			}
		}

		foreach my $v ( keys %$sites ) {
			$needed_sites->{$v} = 1
				if $sites->{$v}->tag("operator")
					&& $sites->{$v}->tag("operator") =~ $operator;

			foreach my $m ( $sites->{$v}->members ) {
				next
					unless $m->member_type eq 'relation'
						&& $relations->{ $m->ref }
						&& $relations->{ $m->ref }->tag("type") eq 'multipolygon';

				$needed_multipolygons->{ $m->ref } = 1;
			}
		}

		foreach my $r ( keys %$relations ) {
			delete $relations->{$r} and delete $line_variants->{$r}
				if $relations->{$r}->tag("type") eq 'route' && !$needed_variants->{$r};

			delete $relations->{$r}
				and delete $sites->{$r}
				if $relations->{$r}
					&& $relations->{$r}->tag("type") eq 'public_transport'
					&& !$needed_sites->{$r};

			delete $relations->{$r}
				if $relations->{$r}
					&& $relations->{$r}->tag("type") eq 'multipolygon'
					&& !$needed_multipolygons->{$r};
		}

		my $needed_ways = {};
		foreach my $r ( values %$relations ) {
			for ( $r->members ) {
				$needed_ways->{ $_->ref } = 1 if $_->member_type eq 'way';
				$nodes->{ $_->ref }       = 1 if $_->member_type eq 'node';
			}
		}

		foreach my $w ( keys %$ways ) {
			if ( $needed_ways->{$w} ) {
				$w = $ways->{$w};
				$nodes->{$_} = 1 for $w->nodes;
			}
			else {
				delete $ways->{$w};
			}
		}
	}

	$log->info("Reading osm data (stage two): $osm_file");
	unless ( Geo::OSM::OsmReader->init($pr_second)->load($osm_file) ) {
		$log->logdie("Failed to parse osm file: $osm_file");
	}

	$log->info("Parsing osm data...");

	# Parse station relations -> store sub-parts

	# needed modifications:
	#    - parse stop data [relations]
	#    - arrange line_variant elements in line (collapse ways)
	#    - create stop -> shape mapping
	#    - add pathways [entrances]

	for ( values %$lines ) {
		next unless $_->tag("operator") && $_->tag("operator") =~ $operator;

		my $line = $_;

		my $ref = $line->tag( $options->{ref_tag} || "ref" )
			|| $line->tag("name");
		my $type = $line->tag("route_master");
		my $name = $line->tag("name");
		my $op   = $line->tag("operator");

		eval {
			foreach my $line_variant ( map { $line_variants->{ $_->ref } } $_->members )
			{
				eval {
					my ( $linestring, $points ) = (
						process_linestring( $line_variant, $line_segments, $ways, $nodes ), []
					);

					foreach my $stop ( grep { $_->role =~ m/^(?:stop|platform)$/ }
						$line_variant->members )
					{
						my $stop_id = entity_id($stop);

						unless ( $stops->{$stop_id} ) {
							my $osm_object;
							given ( $stop->member_type ) {
								when ("node") {
									$osm_object = $nodes->{ $stop->ref };
								}
								when ("way") {
									$osm_object = $ways->{ $stop->ref };
								}
								when ("relation") {
									$osm_object = $sites->{ $stop->ref };
								}
								default {
									$log->error("Missing OSM Entity for $stop_id");
								}
							}

							#XXX pathways

							$stops->{$stop_id}
								= create_stop( $osm_object, $operator, $nodes, $ways,
								$relations );

							if ( $stops->{$stop_id} ) {
								$stops->{$stop_id}->{stop_id} = $stop_id;
							}
							else {
								delete $stops->{$stop_id};
								next;
							}
						}

						push @$points,
							[ $stop_id, @{ $stops->{$stop_id} }{ 'stop_lat', 'stop_lon' } ];
					}

					# create stop points
					my $p = expand_linestring( $linestring, $points,
						$line_variant->tag("route") =~ m/^(?:trolleybus|bus)$/ );

					# reverse linestring if not enough stops matched
					if ( $p <= 0.5 ) {
						$linestring = [ reverse @$linestring ];
						expand_linestring( $linestring, $points,
							$line_variant->tag("route") =~ m/^(?:trolleybus|bus)$/ );
					}

					my $variant_ref
						= $ref
						|| $line_variant->tag( $options->{ref_tag} || "ref" )
						|| $line_variant->tag("name");

					my $variant_name = $line_variant->tag("name")     || $name;
					my $variant_op   = $line_variant->tag("operator") || $op;
					my $variant_type = $line_variant->tag("route")    || $type;

					push @{ $shapes->{$type}->{$ref} },
						{
						stops       => $points,
						linestring  => $linestring,
						relation_id => $line_variant->id,
						ref         => $variant_ref,
						name        => $variant_name,
						operator    => $variant_op,
						type        => $variant_type,
						};
				};
				if ($@) {
					$log->warn( "Failed to parse line_variant relation "
							. $line_variant->id . ": "
							. $@ );
				}
			}

		};
		if ($@) {
			$log->warn( "Failed to parse line relation " . $_->id . ": " . $@ );
		}
	}

	foreach ( values %$nodes, values %$ways, values %$relations ) {
		my $stop_id = entity_id($_);

		next unless $_->tag("create-stop") && !$stops->{$stop_id};

		$stops->{$stop_id} = create_stop( $_, $operator, $nodes, $ways, $relations );
	}

	return {
		shapes   => $shapes,
		stops    => $stops,
		pathways => $pathways,

		nodes     => $nodes,
		ways      => $ways,
		relations => $relations,
	};
}

=head2 create_stop $site, $operator, $nodes, $ways

Given a valid stop entity, returns a stop object.

=cut

sub create_stop
{
	my ( $site, $operator, $nodes, $ways, $relations ) = @_;
	return unless $site;

	my $stop = {
		stop_name           => $site->tag("name"),
		alt_name            => $site->tag("alt_name"),
		old_name            => $site->tag("old_name"),
		alt_old_name        => $site->tag("alt_old_name"),
		old_alt_name        => $site->tag("old_alt_name"),
		wheelchair_boarding => $site->tag("wheelchair"),
	};

	$stop->{stop_osm_entity} = entity_id($site);

	for (qw/ref:bkv ref:kisalfold ref:hugtfs/) {
		next unless $site->tag($_);

		$stop->{stop_code} = $site->tag($_);
		last;
	}

	if ( $site->isa("Geo::OSM::Relation") ) {

		# area relation
		if ( $site->tag("public_transport")
			=~ m/^(?:stop_area|railway_halt|railway_station|bus_station|stops|ferry_terminal|airport)$/
			)
		{
			$stop->{stops} = [
				map { create_stop( $_, $operator, $nodes, $ways, $relations ) }
					map {
					      $_->member_type eq 'relation'
						? $relations->{ $_->ref }
						: (
						$_->member_type eq 'way' ? $ways->{ $_->ref } : $nodes->{ $_->ref } )
					} grep { !$_->role } $site->members
			];

			if(scalar @{ $stop->{stops} }) {
				my ( $sum_lat, $sum_lon ) = ( 0, 0 );
				$sum_lat += $_->{stop_lat} for @{ $stop->{stops} };
				$sum_lon += $_->{stop_lon} for @{ $stop->{stops} };

				@{$stop}{ "stop_lat", "stop_lon" } = (
					$sum_lat / scalar @{ $stop->{stops} },
					$sum_lon / scalar @{ $stop->{stops} },
				);
			} else {
				return undef;
			}
		}

		# simple stop
		else {
			my ( @platforms, $spoint );
			foreach my $m ( $site->members ) {
				given ( $m->role ) {
					when ("platform") {
						my $p;
						given ( $m->member_type ) {
							when ("node") {
								$p = $nodes->{ $m->ref };
							}
							when ("way") {
								$p = $ways->{ $m->ref };
							}
							when ("relation") {
								$p = $relations->{ $m->ref };
							}
						}
						push @platforms, $p;
					}
					when ("stop") {
						$spoint = $nodes->{ $m->ref };
					}
					when (m/^entrance(?:-(\d+))?$/) {
						if ( $m->member_type eq 'node' && $nodes->{ $m->ref } ) {
							my $entrance = create_stop( $nodes->{ $m->ref }, $operator, $nodes, $ways, $relations );
							$entrance->{traversal_time} = $1 if $1;

							$stop->{entrances} = [] unless $stop->{entrances};
							push @{ $stop->{entrances} }, $entrance;

							# XXX -> pathways?
						}
					}
				}
			}

			unless ( scalar @platforms || $spoint ) {
				$log->warn( "Site relation " . $site->id . " missing platforms & stop point." );
				return;
			}

			if ( scalar @platforms ) {
				if ($spoint) {
					my ( $point, $tp, $closest ) = ( [ undef, $spoint->lat, $spoint->lon ] );
					foreach my $p (@platforms) {
						if ( $p->isa("Geo::OSM::Relation") ) {
							my $closest = 99999999;
							my @ways = grep { $_ }
							           map { $_->member_type eq 'way' ? $ways->{ $_->ref } : undef } $p->members;

							foreach my $w (@ways) {
								my ($linestring) = [
									map { [ $_->lat, $_->lon ] }
									map { $nodes->{$_} } @{ $w->nodes }
								];

								expand_linestring( $linestring, [$point], 0 );

								if( defined $point->[3] && $point->[5] < $closest ) {
									$closest = $point->[5];
									$tp = [ @{ $linestring->[ $point->[3] ] }[ 0, 1 ] ];
								} elsif(!$tp) {
									$tp = $linestring->[0];
								}
							}
						}
						elsif ( $p->isa("Geo::OSM::Way") ) {
							my ($linestring) = [
								map { [ $_->lat, $_->lon ] }
								map { $nodes->{$_} } @{ $p->nodes }
							];

							expand_linestring( $linestring, [$point], 0 );

							if( defined $point->[3] ) {
								$tp = [ @{ $linestring->[ $point->[3] ] }[ 0, 1 ] ];
							} else {
								$tp = $linestring->[0];
							}
						}
						else {
							$tp = [ $p->lat, $p->lon ];
						}

						if ( !$closest
							|| sqrt( $tp->[0]**2 + $tp->[1]**2 )
							< sqrt( $closest->[0]**2 + $closest->[1]**2 ) )
						{
							$closest = $tp;
						}
					}

					@{$stop}{ "stop_lat", "stop_lon" } = @$closest;
				}
				else {
					my $platform = $platforms[0];

					if ( $platform->isa("Geo::OSM::Way") ) {
						$platform = $nodes->{ $platform->nodes->[0] };
					}
					$spoint = $platform;

					@{$stop}{ "stop_lat", "stop_lon" } = ( $platform->lat, $platform->lon );
				}
			}
			else {
				@{$stop}{ "stop_lat", "stop_lon" } = ( $spoint->lat, $spoint->lon );
			}

			@{$stop}{ "stop_point_lat", "stop_point_lon" } = ( $spoint->lat, $spoint->lon );
		}
	}
	elsif ( $site->isa("Geo::OSM::Node") ) {
		@{$stop}{ "stop_lat", "stop_lon" } = ( $site->lat, $site->lon );
	}
	elsif ( $site->isa("Geo::OSM::Way") ) {
		$site = $nodes->{ $site->nodes->[0] };
		@{$stop}{ "stop_lat", "stop_lon" } = ( $site->lat, $site->lon );
	}
	else {

		# AHE?
	}

	return $stop;
}

=head2 handle_line_segment

Returns a list of ways contained within a line_segment relation.

=cut

sub handle_line_segment
{
	my ($e) = (@_);
	return [ map { ( !$_->role && $_->member_type eq 'way' ) ? $_->ref : () } $e->members ];
}

=head2 sort_ways

Takes a list of OSM::Way objects, and returns a continuous list of osm node id's.

=cut

sub sort_ways(@)
{
	my $log = Log::Log4perl::get_logger(__PACKAGE__);

	my @ways = map { [ $_->nodes ] } @_;

	foreach my $i ( 0 .. $#ways - 1 ) {
		my ( $prev, $next ) = @ways[ $i, $i + 1 ];

		# A-B B-C
		next if ( $prev->[-1] eq $next->[0] );

		# A-B C-B
		if ( $prev->[-1] eq $next->[-1] ) {
			$ways[ $i + 1 ] = [ reverse @{$next} ];
			next;
		}

		# B-A B-C
		if ( $prev->[0] eq $next->[0] ) {
			$ways[$i] = [ reverse @{$prev} ];
			next;
		}

		# B-A C-B
		if ( $prev->[0] eq $next->[-1] && $i == 0 ) {
			@ways[ $i, $i + 1 ] = ( [ reverse @{$prev} ], [ reverse @{$next} ] );
			next;
		}

		# The two ways don't have matching nodes, not much we can do
		$log->warn( "Not continous [$LS_REL]... $prev->[0] [$i]-> $prev->[-1] => $next->[0] ["
				. ( $i + 1 )
				. "]-> $next->[-1]" );
	}

	return map {@$_} @ways;
}

=head2 process_linestring

Takes a list of ways/line_segments and turns it into a continuous list of OSM::Node
objects.

=cut

sub process_linestring
{
	my ( $e, $line_segments, $ways, $nodes ) = @_;

	$LS_REL = $e->id;

	return [
		map { [ $nodes->{$_}->lat, $nodes->{$_}->lon ] } sort_ways(
			map { $ways->{$_} }
				map {
				$_->member_type eq 'relation' && $line_segments->{ $_->ref }
					? @{ $line_segments->{ $_->ref } }
					: $_->ref
				} grep { !$_->role } $e->members
		)
	];
}

=head2 expand_linestring $linestring, $points, $right_only

Takes a linestring, and associated stops, splitting the linestring on the point
closest to each stop. Also extends each stop with the index of the node closest
to it within the expanded/new linestring.

=cut

our $MIN_STOP_MATCH_DISTANCE = 50; # meters

sub expand_linestring
{
	my ( $linestring, $points, $right_only ) = @_;

	my $length = $#{$linestring};
	for ( my $i = 0; $i < $length; $i++ ) {
	    my ($A, $B) = ($linestring->[$i], $linestring->[ $i + 1 ] );

		next unless $A->[0] == $B->[0] && $A->[1] == $B->[1];

		splice( @{$linestring}, $i, 1 );
		$length--;
		$i--;
	}

	unless(scalar @$points) {
		return 0;
	}

	#$Data::Dumper::Indent = 0;
	#$Data::Dumper::Useqq = 1;
	#print Data::Dumper::Dumper( $linestring, $points, $right_only ) . "\n";

	local $SIG{ALRM} = sub { alarm 0; die "Overtimed trying to expand linestring..."; };
	alarm 5;
	my @match = _expand_linestring( [@$linestring], $points, $right_only );
	alarm 0;

	splice(@$linestring, 0);
	push(@$linestring, @{$match[1]});

	foreach(0 .. $#$points)
	{
		if(defined  $match[2 + $_])
		{
			$points->[$_][3] = $match[2 + $_];
			$points->[$_][5] = 0xDEADBEEF;
		} else {
			$points->[$_][3] = undef;
			$points->[$_][5] = 9999999999999;
		}
	}

	#print Data::Dumper::Dumper( $linestring, $points, $right_only, $#$linestring ) . "\n";
	
	return $match[0] / scalar @$points;
}

sub _expand_linestring
{
	state $geo_distance = Geo::Distance->new;

	my ( $linestring, $points, $right_only ) = @_;
	my ($stop, @places, @matches) = ($points->[0]); # matches -> ([dist, i, insert, [x, y]])

	my $length = $#{$linestring};
	for ( my $i = 0; $i < $length; $i++ ) {
		my ( $dist, $type, @P );

		my (@A, @B, @C);
	    @A = @{ $linestring->[$i] };
		@B = @{ $linestring->[ $i + 1 ] };
		@C = @$stop[ 1, 2 ];

		@P = _way_point( @A, @B, @C );

		if($i == 0 && $A[0] == $C[0] && $A[1] == $C[1])
		{
			push @places, [ 0, $i, 0, \@A ];
		}
		elsif($B[0] == $C[0] && $B[1] == $C[1])
		{
			push @places, [ 0, $i+1, 0, \@B ];
		}
		elsif(scalar @P)
		{
			$dist = $geo_distance->distance('meter', @P => @C);
	   		next if $dist > $MIN_STOP_MATCH_DISTANCE;

			next
				if $right_only
				&& node_sideof_way( [ @C[ 1, 0 ] ], [ [ @A[ 1, 0 ] ], [ @B[ 1, 0 ] ] ] ) == -1;

			push @places, [ $dist, $i, 1, \@P ];
		}
		else {
			state ($dist1, $dist2);
			$dist = $geo_distance->distance('meter', @B => @C);

			if($i == 0) {
				$dist1 = $geo_distance->distance('meter', @A => @C);
				$dist = $dist1 < $dist ? $dist1 : $dist;
			} else {
				$dist1 = 9999999999;
			}

	   		next if $dist > $MIN_STOP_MATCH_DISTANCE;

			next
				if $right_only
				&& node_sideof_way( [ @C[ 1, 0 ] ], [ [ @A[ 1, 0 ] ], [ @B[ 1, 0 ] ] ] ) == -1;

			($type, @P) = $dist1 == $dist ? (0, @A) : (1, @B);
			push @places, [ $dist, $i + $type, 0, \@P ];
		}
	}

	unless(scalar @places)
	{
		if($#$points > 0) {
			my $substops = [ @{$points}[ 1 .. $#$points ] ];
			my ( $submatches, $newsublinestring, @submatches )
				= _expand_linestring( $linestring, $substops, $right_only );

			return ( $submatches, $newsublinestring, undef, @submatches);
		} else {
			return ( 0, $linestring, undef);
		}
	}

	@places = sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @places;

	my @placematches = ();    # score, return matches
	my $failedoffset = $#$linestring + 1;
	foreach my $place ( @places) {
		next if $place->[1] + $place->[2] > $failedoffset;

		my ( $lineoffset, $count, $newlinestring, @matches )
			= ( $place->[1] + $place->[2], 1, [@$linestring], () );
		splice( $newlinestring, $lineoffset, 0, $place->[3] ) if $place->[2];

		unless ($#$points) {
			push @placematches, [ 1, $newlinestring, $lineoffset ];
			last;
		}

		if ( $lineoffset < $#$newlinestring ) {
			my $substops = [ @{$points}[ 1 .. $#$points ] ];
			my $sublinestring = [ @{$newlinestring}[ $lineoffset .. $#$newlinestring ] ];

			my ( $submatches, $newsublinestring, @submatches )
				= _expand_linestring( $sublinestring, $substops, $right_only );

			splice $newlinestring, $lineoffset;
			push $newlinestring, @$newsublinestring;

			$count += $submatches;

			@matches = map { defined $_ ? $_ + $lineoffset : undef } @submatches;
		}
		else {
			@matches = map { (undef) } 1 .. $#$points;
		}

		push @placematches, [ $count, $newlinestring, $lineoffset, @matches ];
		last if $count == scalar @$points;

		$failedoffset = $lineoffset;
	}

	@placematches = sort { $b->[0] <=> $a->[0] } @placematches;
	return @{ $placematches[0] };
}

sub _way_point
{
	use constant { A0 => 0, A1 => 1, B0 => 2, B1 => 3, C0 => 4, C1 => 5 };
	state ($r_numerator, $r_denomenator, $r, @P);

	$r_numerator
		= ( $_[C0] - $_[A0] ) * ( $_[B0] - $_[A0] ) + ( $_[C1] - $_[A1] ) * ( $_[B1] - $_[A1] );
	$r_denomenator
		= ( $_[B0] - $_[A0] ) * ( $_[B0] - $_[A0] ) + ( $_[B1] - $_[A1] ) * ( $_[B1] - $_[A1] );
	$r = $r_numerator / $r_denomenator;

	return () unless $r >= 0 && $r <= 1;

	@P = ( $_[A0] + $r * ( $_[B0] - $_[A0] ), $_[A1] + $r * ( $_[B1] - $_[A1] ) );
	return @P;
}

=cut

=head2 node_sideof_way [lat, lon], [[lat, lon], [lat, lon]]

Returns: 1 = right, 0 = inline, -1 = left

=cut

sub node_sideof_way
{
	my ( $node, $segment ) = @_;

	# Area of the formed triangle, singdness direction
	my $s = ( $segment->[1][0] - $segment->[0][0] ) * ( $node->[1] - $segment->[0][1] )
		- ( $segment->[1][1] - $segment->[0][1] ) * ( $node->[0] - $segment->[0][0] );

	return 1  if $s < 0;
	return -1 if $s > 0;
	return 0;
}

=head2 new $options, $osm [, $gtfs]

=head3 options

=over 3

=item remove_geometryless [ 1 | 0 ]

Remove trips/routes for which no geometry data could be paired?

=item trip_line_variants($trip, $route, $data, $gtfs ) -> [$line_variants]

Callback to return the appropriate line_variants for a trip.

=item stop_is_match ( $stop_osm, $stop_gtfs, $trip, $route, $data, $gtfs ) -> 0 | 1

Callback to determine if the osm/timetable stop data matches.

By default a simple do-the-names match heuristic is used.
The gtfs data's stop_name is expected to be included with the trip's stop_times.

=item create_stop($stop_osm, $stop_gtfs, $trip, $route, $data, $gtfs ) -> id

Callback for the creation of an appropriate (gtfs) stop object. May return the
id of an existing stop.

=item skipped_trip ( $trip, $route, $data, $gtfs )

Callback for when a trip is skipped (no useable line_variant exists).

=item skipped_route ( $route, $data, $gtfs )

Callback for when no trips could be created for a route.

=item finalize_trip ( $trip, $route, $data, $gtfs )

Callback for when a trip has been fully processed.

=item finalize_route ( $route, $data, $gtfs )

Callback for when a route has been fully processed.

=back

If $gtfs is provided C<merge> is automatically called,
it SHOULD NOT be called again on the returned object.

If no $gtfs is provided, C<merge> may be called as many times as needed,
but C<finalize_statistics> needs to be called afte the last merge.

=cut

sub new
{
	my ( $class, $options, $osm_data, $gtfs_data ) = @_;

	my $self = bless {
		routes      => [],
		trips       => [],
		stops       => {},
		match_cache => {},
		shape_cache => {},
		pathways    => {},
		statistics  => undef,
		osm         => undef,
	}, $class;

	$self->{options} = {
		remove_geometryless => 1,
		stop_is_match       => \&default_stop_is_match,
		variant_match_hash  => \&default_variant_match_hash,
		create_stop         => \&default_create_stop,
		trip_line_variants  => \&default_trip_line_variants,
		skipped_trip        => \&default_skipped_trip,
		skipped_route       => \&default_skipped_route,
		finalize_trip       => \&default_finalize_trip,
		finalize_route      => \&default_finalize_route,
		%$options
	};

	$self->{osm} = $osm_data;

	if ($gtfs_data) {
		$self->merge($gtfs_data);
		$self->finalize_statistics;
	}

	return $self;
}

=head2 merge $gtfs

Merges OSM data with timetables.

	# timetable data: { routes => [], trips => [] }

Returned:
	{
		routes   => [{ ..., trips => [] }, ...],
		stops    => { stop_id => {} },
		pathways => {},
		osm      => $osm,
	}

=cut

sub merge
{
	my ( $data, $gtfs ) = @_;
	my $options = $data->{options};

	my $log = Log::Log4perl::get_logger(__PACKAGE__);

	# XXX: Pathways...

	$data->{routes}   = [];
	$data->{trips}    = [];
	$data->{pathways} = [];

	if ( ref $gtfs->{routes} eq 'HASH' ) {
		$gtfs->{routes} = [ sort { $a->{route_id} cmp $b->{route_id} } values %{ $gtfs->{routes} } ];
	}

	if ( $gtfs->{trips} ) {
		my %routes = map { $_->{trips} = []; $_->{route_id} => $_ } @{ $gtfs->{routes} };
		foreach (
			ref $gtfs->{trips} eq 'ARRAY' ? @{ $gtfs->{trips} } : values %{ $gtfs->{trips} } )
		{
			push @{ $routes{ $_->{route_id} }->{trips} }, $_;
		}
	}

	unless ( $data->{statistics} ) {
		$data->{statistics} = {
			unused_routes   => {},
			unused_variants => {},
			unused_stops    => {},
		};

		for my $rt ( keys %{ $data->{osm}->{shapes} } ) {
			for my $rsn ( keys %{ $data->{osm}->{shapes}->{$rt} } ) {
				$data->{statistics}->{unused_routes}->{"$rt-$rsn"} = {
					route_short_name => $rsn,
					route_type       => $rt,
				};

				for my $v ( @{ $data->{osm}->{shapes}->{$rt}->{$rsn} } ) {
					$data->{statistics}->{unused_variants}->{"$rt-$rsn-$v->{relation_id}"} = {
						route_short_name => $rsn,
						route_type       => $rt,
						trip_relation    => $v->{relation_id},
					};

					for my $s ( @{ $v->{stops} } ) {
						$data->{statistics}->{unused_stops}->{
							"$rt-$rsn-$v->{relation_id}-$data->{osm}->{stops}->{$s->[0]}->{stop_osm_entity}"
							} = {
							route_short_name => $rsn,
							route_type       => $rt,
							trip_relation    => $v->{relation_id},
							stop_osm_entity =>
								$data->{osm}->{stops}->{ $s->[0] }->{stop_osm_entity},
							stop_name => $data->{osm}->{stops}->{ $s->[0] }->{stop_name},
							};
					}
				}
			}
		}
	}

ROUTE:
	foreach my $route ( @{ $gtfs->{routes} } ) {
		my @new_trips = ();
		$log->info("Processing route: $route->{route_id}");

	TRIP:
		foreach my $trip ( @{ $route->{trips} } ) {
			my (@score);
			my @variants;

			@variants = $options->{trip_line_variants}->( $trip, $route, $data, $gtfs );
			unless ( scalar @variants ) {
				unless ( $data->{statistics}->{missing_route}->{ $route->{route_id} } ) {
					$data->{statistics}->{missing_route}->{ $route->{route_id} } = {
						route_id         => $route->{route_id},
						route_type       => $route->{route_type},
						route_short_name => $route->{route_short_name},
						route_long_name  => $route->{route_long_name},
					};
				}
				$data->{statistics}->{missing_route}->{ $route->{route_id} }->{count}++;

				my $ret = $options->{skipped_trip}->( $trip, $route, $data, $gtfs );
				if ( $ret && ref $ret ) {
					push @new_trips, $ret;
				}
				next TRIP;
			}

			$log->debug("Processing trip: $trip->{trip_id}");
			
			my $key = $options->{variant_match_hash}->($trip, $route, $data, $gtfs);
			if($data->{match_cache}->{$key}) {
				@score = @{ $data->{match_cache}->{$key} };
			} else {

				# Score each variant on which is most likely match
				#	Stops are matched to the variant from the trip
				#	* This does have problems, eg. if a variant contains a circle, while a trip
				#	  travels only a part of said circle,  we find the last stop of the trip as
				#	  the first stop of the variant.
				#	  To avoid this, if a stop_time is skipped, another score is also created with
				#	  the same variant, but with said stop in the variant skipped.
				#
				# A variant's score is:
				#     (matched stops in the trip) - (unmatched stops in the variant)
				foreach my $variant (@variants) {
					my $variant_start = 0;
					my ($matches, $saved) = ({}, 0);

				VARIANT:
					{
						my $temp = [ 0, [], $variant ];
						my ( $i, $j ) = ( $variant_start, 0 );

						$variant_start = undef;

						for ( ; $i <= $#{ $variant->{stops} }; $i++ ) {
							my $starter = $temp->[0];

							for ( my $k = $j; $k <= $#{ $trip->{stop_times} }; $k++ ) {
								next
									if defined $matches->{"$i $k"} && !$matches->{"$i $k"};

								my $osm_stop
									= $data->{osm}->{stops}->{ $variant->{stops}->[$i]->[0] };
								my $gtfs_stop
									= $trip->{stop_times}->[$k]->{stop_id}
									? $gtfs->{stops}->{ $trip->{stop_times}->[$k]->{stop_id} }
									: $trip->{stop_times}->[$k];

								unless( $matches->{"$i $k"} ) {
									$matches->{"$i $k"} = $options->{stop_is_match}
										->( $osm_stop, $gtfs_stop, $trip, $route, $data, $gtfs );

									next unless $matches->{"$i $k"};
								}

								push @{ $temp->[1] },
									[ $variant->{stops}->[$i], $k ];

								$temp->[0]++;

								$variant_start = $i + 1    # A stop time was skipped
									if !$variant_start && $j != $k;

								$j = $k + 1;
								last;
							}
						}

						if ( $temp->[0] >= 2 ) {
							$temp->[0]
								= $temp->[0] 
								/ ( $#{ $trip->{stop_times} } + 1 )
								- ( $#{ $variant->{stops} } - $temp->[0] )
								/ $#{ $variant->{stops} };
							push @score, $temp;
						}

						redo VARIANT if $variant_start;
					}
				}
				unless ( scalar @score ) {
					$data->{statistics}->{skipped_trip}->{ $trip->{trip_id} } = {
						trip_id          => $trip->{trip_id},
						route_id         => $route->{route_id},
						route_type       => $route->{route_type},
						route_short_name => $route->{route_short_name},
					};

					my $ret = $options->{skipped_trip}->( $trip, $route, $data, $gtfs );
					if ( $ret && ref $ret ) {
						push @new_trips, $ret;
					}
					next TRIP;
				}

				@score = @{ ( sort { $b->[0] <=> $a->[0] } @score )[0] };
				$data->{match_cache}->{$key} = \@score;
			}

			unless (@score) {
				$data->{statistics}->{skipped_trip}->{ $trip->{trip_id} } = {
					trip_id          => $trip->{trip_id},
					route_id         => $route->{route_id},
					route_type       => $route->{route_type},
					route_short_name => $route->{route_short_name},
				};

				my $ret = $options->{skipped_trip}->( $trip, $route, $data, $gtfs );
				if ( $ret && ref $ret ) {
					push @new_trips, $ret;
				}
				next TRIP;
			}

			$log->debug("Found variant: $score[2]->{relation_id}");

			# Update unused statistics
			delete $data->{statistics}->{unused_routes}->{"$score[2]->{type}-$score[2]->{ref}"};
			delete $data->{statistics}->{unused_variants}
				->{"$score[2]->{type}-$score[2]->{ref}-$score[2]->{relation_id}"};

			# If a shape exists, delete it since we're creating new ones
			delete $trip->{shape};
			delete $trip->{shape_id};

			my $stops = 0;
			foreach my $d ( @{ $score[1] } ) {
				my ( $point, $stop_time ) = @$d;
				my ($stop_id) = $point->[0];
				$stop_time = $trip->{stop_times}->[$stop_time];

				my $osm_stop = $data->{osm}->{stops}->{$stop_id};

				if ( $stop_time->{stop_id} ) {
					my $gtfs_stop = $gtfs->{stops}->{ $stop_time->{stop_id} };
					foreach ( keys %$gtfs_stop ) {
						$stop_time->{$_} = $gtfs_stop->{$_} unless $stop_time->{$_};
					}
				}

				$stop_id = $options->{create_stop}(
					$data->{osm}->{stops}->{$stop_id},
					$stop_time, $trip, $route, $data, $gtfs
				);

				$stop_time->{closest} = $point->[3];
				$stop_time->{stop_id} = $stop_id;

				# Update unused statistics
				delete $data->{statistics}->{unused_stops}->{
					"$score[2]->{type}-$score[2]->{ref}-$score[2]->{relation_id}-$data->{osm}->{stops}->{$stop_id}->{stop_osm_entity}"
					};
			}

			# Warn/Remove stops with missing geometry
			{
				my $path = join '-',
					map { $_->{stop_code} || $_->{stop_name} || $_->{stop_id} }
					@{ $trip->{stop_times} };

				for ( my $k = $#{ $trip->{stop_times} }; $k >= 0; $k-- ) {
					next
						if $trip->{stop_times}->[$k]->{stop_id}
							&& $data->{stops}->{ $trip->{stop_times}->[$k]->{stop_id} };

					# Only complain about stops, which actually pickup/dropoff people
					if (   !$trip->{stop_times}->[$k]->{drop_off_type}
						|| !$trip->{stop_times}->[$k]->{pickup_type} )
					{
						my $gtfs_stop
							= $trip->{stop_times}->[$k]->{stop_id}
							? $gtfs->{stops}->{ $trip->{stop_times}->[$k]->{stop_id} }
							: $trip->{stop_times}->[$k];

						$log->warn(
							"Missing stop: <$trip->{trip_id}> => <$gtfs_stop->{stop_name}"
								. (
								$gtfs_stop->{stop_code}
								? " ($gtfs_stop->{stop_code})"
								: ""
								)
								. ">"
						);

						my $key
							= $route->{route_id} . '_' . $path . '_' . $gtfs_stop->{stop_name};

						unless ( $data->{statistics}->{missing_stop}->{$key} ) {
							$data->{statistics}->{missing_stop}->{$key} = {
								trip_id          => $trip->{trip_id},
								route_id         => $route->{route_id},
								route_type       => $route->{route_type},
								route_relation   => $score[2]->{relation_id},
								route_short_name => $route->{route_short_name},
								stop_code        => $gtfs_stop->{stop_code},
								stop_name        => $gtfs_stop->{stop_name},
							};
						}
						$data->{statistics}->{missing_stop}->{$key}->{count}++;
					}

					if ( $options->{remove_geometryless} ) {
						splice( @{ $trip->{stop_times} }, $k, 1 );
					}
				}

				# XXX: destructive, can't call skipped_trip...
				next TRIP unless @{ $trip->{stop_times} };
			}

			# Try creating geometry
			{
				for my $i (0 .. $#{ $trip->{stop_times} } ) {
					$trip->{stop_times}[$i]->{shape_dist_traveled} = $i unless $trip->{stop_times}[$i]->{shape_dist_traveled};
				}

				my ( $prev_stop, @geom ) = ( undef, () );
				foreach my $stop ( @{ $trip->{stop_times} } ) {
					next unless $stop->{stop_id};
					next unless $prev_stop;

					unless ( defined $stop->{closest} ) {
						$log->warn(
							      "Failed to find closest stop<>way for variant <"
								. $score[2]->{relation_id}
								. "> <$trip->{trip_id}> <$data->{stops}->{$stop->{stop_id}}->{stop_name}"
								. (
								$data->{stops}->{ $stop->{stop_id} }->{stop_code}
								? " ($data->{stops}->{$stop->{stop_id}}->{stop_code})"
								: ""
								)
								. ">"
						);

						$data->{statistics}->{unlinked_stops}->{
							"$score[2]->{type}-$score[2]->{ref}-$score[2]->{relation_id}-$data->{stops}->{$stop->{stop_id}}->{stop_osm_entity}"
							} = {
							trip_id          => $trip->{trip_id},
							route_id         => $route->{route_id},
							route_type       => $route->{route_type},
							route_short_name => $route->{route_short_name},
							trip_relation    => $score[2]->{relation_id},
							stop_code => $data->{stops}->{ $stop->{stop_id} }->{stop_code},
							stop_name => $data->{stops}->{ $stop->{stop_id} }->{stop_name},
							stop_osm_entity =>
								$data->{stops}->{ $stop->{stop_id} }->{stop_osm_entity},
							};
					}

					unless ( defined $prev_stop->{closest} && defined $stop->{closest} ) {
						push @geom,
							[
							@{ $data->{stops}->{ $prev_stop->{stop_id} } }{ 'stop_lat',
								'stop_lon' },
							$prev_stop->{shape_dist_traveled}
							];
						delete $prev_stop->{closest};
						next;
					}

					my $i = 1;
					push @geom,
						[
						@{ $score[2]->{linestring}->[ $prev_stop->{closest} ] },
						$prev_stop->{shape_dist_traveled}
						];
					push @geom, map {
						$i++;
						[ @$_, $prev_stop->{shape_dist_traveled} + $i / 10000 ];
						} @{ $score[2]->{linestring} }
						[ $prev_stop->{closest} + 1 .. $stop->{closest} - 1 ];

					delete $prev_stop->{closest};
				}
				continue {
					$prev_stop = $stop
						if $stop->{stop_id};
				}

				if ( $prev_stop->{closest} ) {
					push @geom,
						[
						@{ $score[2]->{linestring}->[ $prev_stop->{closest} ] },
						$prev_stop->{shape_dist_traveled}
						];
				}
				else {
					push @geom,
						[
						@{ $data->{stops}->{ $prev_stop->{stop_id} } }{ 'stop_lat',
							'stop_lon' },
						$prev_stop->{shape_dist_traveled}
						];
				}
				delete $prev_stop->{closest};

				$trip->{shape} = {
					shape_id     => 'HUGTFS_SHAPE_' . $trip->{trip_id},
					shape_points => [
						map {
							{
								shape_pt_lat        => $_->[0],
								shape_pt_lon        => $_->[1],
								shape_dist_traveled => $_->[2],
							}
							} @geom
					],
				};

				my $shape_sha = shape_sha256( $trip->{shape} );
				if ( $data->{shape_cache}->{$shape_sha}
					&& shape_equal( $trip->{shape}, $data->{shape_cache}->{$shape_sha} ) )
				{
					$trip->{shape_id} = $data->{shape_cache}->{$shape_sha}->{shape_id};
					delete $trip->{shape};
				}
				else {
					$data->{shape_cache}->{$shape_sha} = shape_clone( $trip->{shape} );
				}
			}

			push @new_trips, $trip;
			$options->{finalize_trip}( $trip, $route, $data, $gtfs );

			push @{ $data->{trips} }, $trip;
		}

		unless ( scalar @new_trips ) {
			$options->{skipped_route}( $route, $data, $gtfs );
		}
		else {
			$route->{trips} = \@new_trips;
			push @{ $data->{routes} }, $route;

			$options->{finalize_route}( $route, $data, $gtfs );
		}
	}

	return $data;
}

=head2 finalize_statistics

=cut

sub finalize_statistics
{
	my $data = shift;

	my $trips = {};

	for my $t ( values %{ $data->{statistics}->{unused_trips} } ) {
		$trips->{ $t->{trip_relation} } = 1;
	}

	for ( keys %{ $data->{statistics}->{unused_stops} } ) {
		delete $data->{statistics}->{unused_stops}->{$_}
			if $trips->{ $data->{statistics}->{unused_stops}->{$_}->{trip_relation} };
	}
}

sub default_stop_is_match
{
	my ( $stop_osm, $stop_gtfs, $trip, $route, $data, $gtfs ) = @_;
	my ( $name, $alt_name, $old_name, $alt_old_name, $old_alt_name ) = (
		$stop_osm->{stop_name},
		$stop_osm->{alt_name}     || 'NOBODY',
		$stop_osm->{old_name}     || 'NOBODY',
		$stop_osm->{alt_old_name} || 'NOBODY',
		$stop_osm->{old_alt_name} || 'NOBODY'
	);

	return $stop_osm->{stop_code} =~ m/\b$stop_gtfs->{stop_code}\b/
		if $stop_osm->{stop_code} && $stop_gtfs->{stop_code};

	die Data::Dumper::Dumper($stop_osm, $stop_gtfs) unless $name && $stop_gtfs->{stop_name};
	return 0 unless $name && $stop_gtfs->{stop_name};

	local $ENV{LC_CTYPE} = 'hu_HU.UTF-8';
	{
		use locale;
		return $stop_gtfs->{stop_name}
			=~ m/^(?:\Q$name\E|\Q$alt_name\E|\Q$old_name\E|\Q$alt_old_name\E|\Q$old_alt_name\E)$/i;
	}
}

sub default_create_stop
{
	my ( $stop_osm, $stop_gtfs, $trip, $route, $data, $gtfs ) = @_;
	my $stop_id = $stop_osm->{stop_id};

	if ( !$data->{stops}->{$stop_id} ) {
		my $stop = $data->{stops}->{$stop_id} = {
			%$stop_osm,
			stop_id       => $stop_id,
			stop_name     => $stop_gtfs->{stop_name},
			stop_url      => undef,
			stop_code     => ($stop_gtfs->{stop_code} || $stop_osm->{stop_code} || undef),
			location_type => 0,
			(
				($stop_gtfs->{stop_zone} || $stop_gtfs->{zone_id})
				? ( zone_id => ($stop_gtfs->{stop_zone} || $stop_gtfs->{zone_id}) )
				: ()
			),
		};

		$stop->{wheelchair_boarding} = $stop_gtfs->{wheelchair_boarding}
			if $stop_gtfs->{wheelchair_boarding};

		delete $stop->{stop_zone};
		delete $stop->{alt_name};
		delete $stop->{old_name};
		delete $stop->{alt_old_name};
		delete $stop->{old_alt_name};
	}

	if ( $stop_gtfs->{arrival_time} || $stop_gtfs->{departure_time} || $stop_gtfs->{stop_time} )
	{
		delete $stop_gtfs->{$_}
			for
			qw/stop_name stop_desc stop_code stop_zone zone_id stop_lat stop_lon location_type parent_station wheelchair_boarding/;
	}

	if($data->{stops}->{$stop_id}->{entrances}) {
		foreach my $entrance (@{$data->{stops}->{$stop_id}->{entrances}}) {
			my $t = $entrance->{traversal_time} || 30;
			delete $entrance->{traversal_time};

			$entrance->{stop_name} = $entrance->{name} || $data->{stops}->{$stop_id}->{stop_name};
			$entrance->{stop_id}   = $stop_id . "_entrance_" . $entrance->{stop_osm_entity};

			# XXX: pathways
			push @{ $data->{stops}->{$stop_id}->{pathways} },
				{
				pathway_id     => $stop_id . "-" . $entrance->{stop_id},
				from_stop_id   => $stop_id,
				to_stop_id     => $entrance->{stop_id},
				pathway_type   => 'stop-street',
				traversal_time => $t
				};
			push @{ $data->{stops}->{$stop_id}->{pathways} },
				{
				pathway_id     => $entrance->{stop_id} . "-" . $stop_id,
				to_stop_id     => $stop_id,
				from_stop_id   => $entrance->{stop_id},
				pathway_type   => 'street-stop',
				traversal_time => $t
				};

			delete $entrance->{$_} for qw/alt_name old_name alt_old_name old_alt_name/;
		}
	}

	return $stop_id;
}

sub default_variant_match_hash
{
	my ( $trip, $route, $data, $gtfs ) = @_;
	my $key = $route->{route_id};

	for my $st (@{ $trip->{stop_times} }) {
		$key .= '$';
		$key .= '<' . ($st->{stop_name} || '') . '>-';
		$key .= '<' . ($st->{stop_code} || '') . '>-';
		$key .= '<' . ($st->{stop_zone} || '') . '>-';
		$key .= '<' . ($st->{stop_id  } || '') . '>-';
	}

	return $key;
}

sub default_trip_line_variants
{
	my ( $trip, $route, $data, $gtfs ) = @_;

	return ()
		unless exists $data->{osm}->{shapes}->{ $route->{route_type} }
			->{ $route->{route_short_name} || $route->{route_long_name} };

	return
		@{ $data->{osm}->{shapes}->{ $route->{route_type} }
			->{ $route->{route_short_name} || $route->{route_long_name} } };
}

sub default_skipped_trip
{
	my ( $trip, $route, $data, $gtfs ) = @_;

	$log->debug("Skipping trip: $trip->{trip_id}");
}

sub default_skipped_route
{
	my ( $route, $data, $gtfs ) = @_;

	$log->warn( "Failed to create routes for <$route->{route_id}> ("
			. ( $route->{route_short_name} || 'undef' ) . ' - '
			. ( $route->{route_long_name}  || 'undef' )
			. ')' );
}

sub default_finalize_trip
{
	my ( $trip, $route, $data, $gtfs ) = @_;

	# NULL
}

sub default_finalize_route
{
	my ( $route, $data, $gtfs ) = @_;

	# NULL
}

sub shape_equal
{
	my ( $a, $b ) = @_;

	return 0 unless $#{ $a->{shape_points} } == $#{ $b->{shape_points} };

	for my $i ( 0 .. $#{ $a->{shape_points} } ) {
		for (qw/shape_pt_lat shape_pt_lon shape_dist_traveled/) {
			return 0 if $a->{shape_points}[$i]{$_} ne $b->{shape_points}[$i]{$_};
		}
	}

	return 1;
}

sub shape_sha256
{
	my $shape    = shift;
	my $longtext = join(
		"",
		(
			map {"<$_->{shape_dist_traveled}|$_->{shape_pt_lon}|$_->{shape_pt_lat}>"}
				@{ $shape->{shape_points} }
		)
	);

	return sha256_hex($longtext);
}

sub shape_clone
{
	my $shape = shift;
	my $new   = {%$shape};

	$new->{shape_points} = [
		map {
			{%$_}
			} @{ $new->{shape_points} }
	];

	return $new;
}

1 + 1 == 2;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
