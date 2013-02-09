#!/usr/bin/env perl

=pod

=cut

use 5.14.0;
use utf8;
use strict;
use warnings qw/ all /;

BEGIN {

	use Log::Log4perl;

	my $conf = q(
    log4perl.appender.Screen         = Log::Log4perl::Appender::Screen
    log4perl.appender.Screen.stderr  = 0
    log4perl.appender.Screen.layout  = Log::Log4perl::Layout::PatternLayout
	log4perl.appender.Screen.layout.ConversionPattern = %d{HH:mm}-%p %m{chomp}%n

    log4perl.category.HuGTFS         = INFO, Screen
);

	Log::Log4perl::init( \$conf );
}

use FindBin;
use lib "$FindBin::Bin/../lib";

use App::Rad qw(ConfigLoader);

use DateTime;
use File::Path;
use File::Spec::Functions qw/ updir curdir catdir catfile /;
use File::Basename;

use DBI;
use DBD::Pg qw(:pg_types);

use POSIX ":sys_wait_h";
use IO::File;
use File::Temp qw/ tempfile tempdir /;
use Archive::Extract;
use Text::CSV::Encoded;

use HuGTFS::Util qw/ slurp burp /;
use HuGTFS::Dumper;
use HuGTFS::KML;
use HuGTFS::SVG;
use YAML ();

use Text::Markdown 'markdown';

use Cwd;

use Data::Dumper;

my $feedsdir = 'feeds';

my $options = {
	base     => [ 'config:s',   'v|verbose+', 'q|quiet+', ],
	download => [ 'automatic!', 'force!', ],
	parse    => [ 'osmfile:s',  'reference_url:s', ],
};

binmode( STDOUT, ':utf8' );
binmode( STDERR, ':utf8' );
binmode( STDIN,  ':utf8' );
STDOUT->autoflush(1);
STDERR->autoflush(1);

my $log = Log::Log4perl::get_logger("HuGTFS::App");

App::Rad->run();

sub setup
{
	my $c = shift;

	chdir catdir( $FindBin::Bin, updir() );

	$c->register_commands(
		qw/db_import db_init db_clean download convert parse deploy deploy_all gtfs kml svg/);

	$c->getopt(
		'v|verbose+',            'q|quiet+',
		'automatic',             'reference_url:s',
		'osmfile:s',             'force',
		'prefix',                'selective:s',
		'stops',                 'shapes',
		'include:s',             'exclude:s',
		'ignore_non_hungarian!', 'purge!',
		'all!',                  'stations!',
		'trips!',                'caltest:s',
	);

	if ( $c->options->{v} ) {
		Log::Log4perl::get_logger("HuGTFS")->more_logging( $c->options->{v} );
	}
	if ( $c->options->{q} ) {
		Log::Log4perl::get_logger("HuGTFS")->less_logging( $c->options->{v} );
	}
}

sub pre_process
{
	my $c = shift;

	if ( $c->options->{config} ) {
		if ( -f $c->options->{config} ) {
			$c->load_config( $c->options->{config} );
		}
		else {
			die "Missing file: " . $c->options->{config};
		}
	}
	elsif ( -f 'config.yml' ) {
		$c->load_config('config.yml');
	}

	if ( $c->config->{osmfile} ) {
		$c->stash->{osmfile} = $c->config->{osmfile};
	}
	if ( defined $c->options->{osmfile} ) {
		$c->stash->{osmfile}
			= $c->options->{osmfile} =~ m/^(?:undef|false|no|none)$/
			? undef
			: $c->options->{osmfile};
	}
}

sub db_setup
{
	my $c = shift;

	if ( !$c->stash->{tables} ) {
		$c->stash->{tables}
			= [
			qw/stops entity_geom entity_gtfs_map/
			];

		$c->stash->{db} = DBI->connect(
			$c->config->{database}->{dsn}, $c->config->{database}->{username},
			$c->config->{database}->{password}, { pg_enable_utf8 => 1, AutoCommit => 1, }
		) or die "Faled to connect to db: $DBI::errstr";
	}
}

sub teardown
{
	my $c = shift;

	if ( $c->stash->{db} ) {
		$c->stash->{db}->disconnect;
	}
}

sub post_process
{
	my $c = shift;

	if ( ( $c->cmd eq 'help' || !$c->is_command( $c->cmd ) ) && $c->output() ) {
		print $c->output();
	}
}

sub db_import : Help(Import a GTFS feed: [--purge] gtfs.zip)
{
	my $c = shift;

	db_setup($c);

	$c->stash->{db}->begin_work;
	$c->stash->{db}->do('SET CONSTRAINTS ALL DEFERRED');

	if ( $c->options->{purge} ) {
		$log->info("Purging previous data...");
		for ( @{ $c->stash->{tables} } ) {
			$c->stash->{db}->do("DELETE FROM $_;") or die "Failed to purge: $DBI::errstr";
		}
	}
	my $origdir = getcwd;

	while ( my $dir = shift @{ $c->argv } ) {
		if ( -f $dir ) {
			my $ae = Archive::Extract->new( archive => $dir );
			$dir = tempdir( CLEANUP => 1 );
			$ae->extract( to => $dir ) or die $ae->error;
		}

		chdir($dir);
		$log->debug("Import: $dir");

		my $csv = Text::CSV::Encoded->new(
			{
				encoding_in    => 'utf8',
				encoding_out   => 'utf8',
				sep_char       => ',',
				quote_char     => '"',
				escape_char    => '"',
				eol            => "\r\n",
				blank_is_undef => 1,
			}
		);

		my ( @csv_cols, @sql_cols, @cols );

		sub bad_csv_data
		{
			my $csv = shift;

			$log->logconfess(
				"Error parsing: " . $csv->error_diag() . "\n" . $csv->error_input() );
		}

		sub time_to_int
		{
			my @m = ( 60 * 60, 60, 1 );
			my $r = 0;
			$r += $_ for ( map { $_ * shift @m } split /:/, shift );
			return $r;
		}

		sub _intersect
		{
			my ( $a, $b ) = @_;
			my %t = map { $_ => 1 } @$a;

			grep { $t{$_} } @$b;
		}

		sub _difference
		{
			my ( $a, $b ) = @_;
			my %t = map { $_ => 1 } @$a;

			grep { !defined $t{$_} } @$b;
		}

		sub _find
		{
			my ( $e, @a ) = @_;
			for ( my $i = $#a; $i >= 0; $i-- ) {
				return $i if $e eq $a[$i];
			}
		}

		sub _cols
		{
			my ( $a, $b ) = @_;

			map { [ _find( $_, @$a ), _find( $_, @$b ) ] } _intersect( $a, $b );
		}

		sub _insert
		{
			my ( $c, $table, $file, $csv, $sql_cols, $csv_cols, $cols, $callback ) = @_;

			my @data = ();
			my $stmt
				= $c->stash->{db}->prepare( "INSERT INTO $table ("
					. ( join ', ', map { $sql_cols->[ $_->[0] ] } @$cols )
					. ") VALUES ("
					. ( join ', ', map { $_ =~ m/time/ ? 'interval ?' : '?' } @$cols )
					. ");" );

			while ( !$file->eof() ) {
				my $line = $file->getline;
				unless ( $csv->parse($line) ) {
					bad_csv_data($csv);
				}

				my @csv_data = map { defined $_ && $_ ne '' ? $_ : undef } $csv->fields();

				my $new_data
					= { map { $csv_cols->[ $_->[1] ] => $csv_data[ $_->[1] ] } @$cols };

				$callback->($new_data) if $callback;

				#push @data, $new_data;

				unless (
					$stmt->execute( map { $new_data->{ $sql_cols->[ $_->[0] ] } } @$cols ) )
				{
					$log->logconfess( Dumper($new_data) );
				}
			}
			$stmt->finish;
		}

		if ( -f './stops.yml' ) {
			$log->info("Loading stops.yml...");

			my $data = YAML::Load( slurp './stops.yml' );

			my $stmt
				= $c->stash->{db}->prepare(
				"INSERT INTO entity_geom (osm_entity_id, entity_lat, entity_lon, entity_level, entity_name, entity_type, entity_names, entity_gtfs_ids, entity_members, entity_polygon) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);"
				);

			# id, type, geom, name, names[], gtfs_stop_ids[], members[], polygon[]

			foreach (qw/stop area interchange/) {
				foreach my $e ( values %{ $data->{ $_ . 's' } } ) {
					$e->{level} = $_;
				}
			}

			foreach my $entity (
				values %{ $data->{stops} },
				values %{ $data->{areas} },
				values %{ $data->{interchanges} }
				)
			{
				foreach my $a (qw/names gtfs_stop_ids members polygon/) {
					$entity->{$a} = '{"'
						. ( join '","', map { $_ =~ s/"/'/g; $_ } @{ $entity->{$a} } ) . '"}';
				}

				unless (
					$stmt->execute(
						$entity->{id},            @{ $entity->{geom} },
						$entity->{level},         $entity->{name},
						$entity->{type},          $entity->{names},
						$entity->{gtfs_stop_ids}, $entity->{members},
						$entity->{polygon}
					)
					)
				{
					$log->logconfess( Dumper($entity) );
				}
			}

			$stmt->finish;
		}

		# import - fare_attributes fare_rules

		chdir($origdir);
	}

	$log->info("Creating stop entity operators...");
	#$c->stash->{db}->do("SELECT entity_geom_update_operator();")
	#	or die "Failed to update entity operators!";

	#$log->info("Creating shape geometries...");
	#$c->stash->{db}->do("SELECT shapes_update_geom();") or die "Failed to create shape geometry!";

	$c->stash->{db}->commit or die "Failed to commit....";

	$c->stash->{db}->do("REINDEX TABLE $_;")  for ( @{ $c->stash->{tables} } );
	$c->stash->{db}->do("VACUUM ANALYZE $_;") for ( @{ $c->stash->{tables} } );
}

sub db_clean : Help(Cleans the database)
{
	my $c = shift;

	db_setup($c);

	$c->stash->{db}->begin_work;

	for ( @{ $c->stash->{tables} } ) {
		$c->stash->{db}->do("TRUNCATE $_ CASCADE;");
	}

	$c->stash->{db}->commit;
}

sub db_init : Help(Initializes the database)
{
	my $c = shift;

	db_setup($c);

	$c->stash->{db}->begin_work;

	$c->stash->{db}->commit;
}

sub download : Help(Downloads agency data: [--force] [--automatic] agency)
{
	my $c      = shift;
	my @args   = scalar @_ ? @_ : @{ $c->argv };
	my $agency = shift @args;

	$c->load_config( catfile curdir(), $feedsdir, $agency, 'config.yml' );
	eval "require " . $c->config->{feedmanager} . ";"
		or die "Failed to load feed manager: $@";

	my $fm = $c->config->{feedmanager}->new(
		options       => $c->config,
		directory     => catdir( curdir(), $feedsdir, $agency ),
		force         => $c->options->{force},
		osm_file      => $c->stash->{osmfile},
		reference_url => '',
	);

	return $fm->download( %{ $c->options } );
}

sub convert : Help(Converts agency data: agency [ agency specific args ] )
{
	my $c = shift;
	my $agency = shift || $c->argv->[0];

	$c->load_config( catfile curdir(), $feedsdir, $agency, 'config.yml' );
	eval "require " . $c->config->{feedmanager} . ";"
		or die "Failed to load feed manager: $@";

	my $fm = $c->config->{feedmanager}->new(
		options       => $c->config,
		directory     => catdir( curdir(), $feedsdir, $agency ),
		osm_file      => $c->stash->{osmfile},
		reference_url => '',
	);

	die "FeedManager doesn't support converting" unless $fm->does('HuGTFS::FeedManagerConvert');

	return $fm->convert( %{ $c->options } );
}


sub parse : Help(Parses agency data: [--osmfile=...] agency [ agency specific args ] )
{
	my $c = shift;
	my $agency = shift || $c->argv->[0];

	$c->load_config( catfile curdir(), $feedsdir, $agency, 'config.yml' );
	eval "require " . $c->config->{feedmanager} . ";"
		or die "Failed to load feed manager: $@";

	my $fm = $c->config->{feedmanager}->new(
		options       => $c->config,
		directory     => catdir( curdir(), $feedsdir, $agency ),
		osm_file      => $c->stash->{osmfile},
		reference_url => '',
	);

	return $fm->parse( %{ $c->options } );
}

sub gtfs :
	Help(Creates a GTFS archive: [--prefix] [--osmfile=...] [--exclude=agency,agency,..] [--include=agency,agency,...] )
{
	my $c = shift;
	$c->getopt( 'prefix!', 'osmfile:s', 'exclude:s', 'include:s' );

	my $dest = $c->argv->[0];
	my ( @all, @include, @exclude ) = ( map {m{^\./(.*)/$}} <./*/> );    # / balance
	@include = split ',', ( $c->options->{include} || '' );
	@exclude = split ',', ( $c->options->{exclude} || '' );

	if ( scalar @_ ) {
		$dest    = pop @_;
		@include = @_;
	}
	$dest ||= 'gtfs.zip';

	if (@include) {
		@all = @include;
	}

	my $dumper = HuGTFS::Dumper->new( prefix => $c->options->{prefix} );
	$dumper->process_shapes;
	$dumper->process_stops;
	$dumper->clean_dir;

	foreach my $d (@all) {
		unless ( scalar grep { $d eq $_ } @exclude ) {
			next unless -f File::Spec->catfile( curdir(), $feedsdir, $d, 'config.yml' );

			if ( -f File::Spec->catfile( $d, "README.txt" ) ) {
				$dumper->readme( slurp( File::Spec->catfile( curdir(), $feedsdir, $d, "README.txt" ) ) );
			}
			$dumper->load_data( File::Spec->catdir( curdir(), $feedsdir, $d, 'gtfs' ) );
		}
	}

	$dumper->postprocess_stops( $c->stash->{osmfile} );
	$dumper->postprocess_shapes;

	$dumper->deinit_dumper;

	$dumper->create_zip($dest) || return 0;

	return 1;
}

sub kml : Help(Create a KML for a GTFS feed: [--kml=gtfs.kmz] gtfs.zip)
{
	my $c = shift;

	HuGTFS::KML->convert( $c->options->{kml} || 'gtfs.kmz', @{ $c->argv } );
}

sub svg :
	Help(Creates an SVG for a GTFS feed:  [--bbox] [--speed] [--fps] -[-buffer] [dest.svg] gtfs.zip )
{
	my $c = shift;

	HuGTFS::SVG->convert( $c->options->{svg} || 'gtfs.svg', $c->options, @{ $c->argv } );
}

our ( $children, %child_status );

sub deploy : Help(Deploy/Archives GTFS data: [--automatic] agency agency2 ... )
{
	my $c = shift;

	my @agencies;
	local ( %child_status, $children );

	sub REAPER
	{
		my $child;

		# If a second child dies while in the signal handler caused by the
		# first death, we won't get another signal. So must loop here else
		# we will leave the unreaped child as a zombie. And the next time
		# two children die we get another zombie. And so on.
		while ( ( $child = waitpid( -1, WNOHANG ) ) > 0 ) {
			$child_status{$child} = $?;
			$children--;
		}
		$SIG{CHLD} = \&REAPER;    # still loathe SysV
	}
	local $SIG{CHLD} = \&REAPER;

	if ( scalar @{ $c->argv } ) {
		@agencies = @{ $c->argv };
	}
	elsif ( $c->options->{automatic} ) {
		foreach my $agency ( grep { -d $_ && $_ ne '..' && $_ ne '.' } <*> ) {
			next unless -f catfile( curdir(), $feedsdir, $agency, 'config.yml' );

			$c->load_config( catfile( curdir(), $feedsdir, $agency, 'config.yml' ) );
			if ( $c->config->{automatic} ) {
				push @agencies, $agency;
			}
		}
		$c->debug( "Canidates: " . join( ", ", @agencies ) );
	}

	foreach my $agency (@agencies) {
		$log->info("Deploy $agency...");

		$c->load_config( catfile curdir(), $feedsdir, $agency, 'config.yml' );
		eval "require " . $c->config->{feedmanager} . ";"
			or die "Failed to load feed manager: $@";

		my $pid = fork();
		if ( $pid == 0 ) {
			my $date = DateTime->now->ymd('');
			my ( $deploy_dir, $latest_dir, $feed_dir, $kml_dir, $reference_dir ) = (
				catdir( $c->config->{deploydir}, $agency, $date ),
				catdir( $c->config->{deploydir}, $agency, "latest" ),
				catdir( $c->config->{deploydir}, $agency, $date, 'feed' ),
				catdir( $c->config->{deploydir}, $agency, $date, 'kml' ),
				catdir( $c->config->{deploydir}, $agency, $date, 'reference' ),
			);
			my ( $gtfs_file, $kml_file, $readme_file ) = (
				catfile( $feed_dir,   'gtfs.zip' ),
				catfile( $kml_dir,    'gtfs.kmz' ),
				catfile( $deploy_dir, 'README' ),
			);

			my $fm = $c->config->{feedmanager}->new(
				options       => $c->config,
				automatic     => 1,
				force         => $c->options->{force},
				directory     => catdir( curdir(), $feedsdir, $agency ),
				osm_file      => $c->stash->{osmfile},
				reference_url => "http://data.flaktack.net/transit/$agency/$date/reference/",
			);

			$0 = "hugtfs.pl deploy $agency";

			if ( $c->options->{automatic} ) {
				$fm->download;
				$fm->parse;
			}

			if ( !-d catdir( $c->config->{deploydir}, $agency ) ) {
				mkdir catdir( $c->config->{deploydir}, $agency );
			}

			mkdir $deploy_dir;
			mkdir $feed_dir;
			mkdir $kml_dir;

			my $dumper = HuGTFS::Dumper->new;
			$dumper->magic( $fm->directory, $agency, $gtfs_file );

			#burp( catfile( $c->config->{deploydir}, $agency, 'README' ),
			#	create_markdown( $dumper->readme ) );
			burp( $readme_file, create_markdown( $dumper->readme ) );
			link( $readme_file, catfile( $feed_dir, 'README' ) );
			link( $readme_file, catfile( $kml_dir,  'README' ) );

			HuGTFS::KML->convert( $kml_file, $gtfs_file );

			if ( -d $fm->data_directory ) {

				sub cpr
				{
					my ( $d, $s ) = @_;
					for ( glob catfile( $d, '*' ) ) {
						if ( -d $_ && $_ ne '.' && $_ ne '..' ) {
							cpr( $_, catdir( $s, basename $_) );
						}
						else {
							link $_, catdir( $s, basename $_);
						}
					}
				}

				mkdir $reference_dir;
				cpr( $fm->data_directory, $reference_dir );
			}

			unlink($latest_dir);
			symlink( $deploy_dir, $latest_dir );

			$log->info("... finished $agency");

			exit(0);
		}
		elsif ( defined $pid ) {
			$children++;
		}
		else {

			# failed to fork
			$log->errordie("Failed to fork for agency: $agency");
		}

		# max 4 processes
		while ( $children > 4 ) {
			sleep 5;
		}
	}

	while ($children) {
		sleep 5;
	}

	if ( $c->options->{all} ) {
		$c->execute('deploy_all');
	}
}

sub deploy_all : Help(Deploys/Archives a feed containing all agencies: agency agency2 ... )
{
	my $c = shift;

	my @agencies;

	$log->info("Deploy all:");

	if ( scalar @{ $c->argv } ) {
		@agencies = @{ $c->argv };
	}

	my $date = DateTime->now->ymd('');
	my ( $deploy_dir, $latest_dir, $feed_dir, $kml_dir, ) = (
		catdir( $c->config->{deploydir}, 'minden', $date ),
		catdir( $c->config->{deploydir}, 'minden', "latest" ),
		catdir( $c->config->{deploydir}, 'minden', $date, 'feed' ),
		catdir( $c->config->{deploydir}, 'minden', $date, 'kml' ),
	);
	my ( $gtfs_file, $kml_file, $readme_file ) = (
		catfile( $feed_dir,   'gtfs.zip' ),
		catfile( $kml_dir,    'gtfs.kmz' ),
		catfile( $deploy_dir, 'README' ),
	);

	mkdir $deploy_dir;
	mkdir $feed_dir;
	mkdir $kml_dir;

	my $dumper = HuGTFS::Dumper->new( prefix => 1 );
	$dumper->process_shapes;
	$dumper->process_stops;
	$dumper->clean_dir;

	foreach my $d (@agencies) {
		$log->info("Loading $d...");

		if ( -f File::Spec->catfile( curdir(), $feedsdir, $d, "README.txt" ) ) {
			$dumper->readme( slurp( File::Spec->catfile( curdir(), $feedsdir, $d, "README.txt" ) ) );
		}
		
		my $dir = File::Spec->catdir( curdir(), $feedsdir, $d, 'gtfs' );
		$dumper->load_data( $dir, $d );
	}

	$dumper->postprocess_stops( $c->stash->{osmfile} );
	$dumper->postprocess_shapes;

	$dumper->deinit_dumper;

	$dumper->create_zip($gtfs_file) || return 0;

	#burp( catfile( $c->config->{deploydir}, "minden", 'README' ),
	#	create_markdown( $dumper->readme ) );
	burp( $readme_file, create_markdown( $dumper->readme ) );
	link( $readme_file, catfile( $feed_dir, 'README' ) );
	link( $readme_file, catfile( $kml_dir,  'README' ) );

	HuGTFS::KML->convert( $kml_file, $gtfs_file );

	unlink($latest_dir);
	symlink( $deploy_dir, $latest_dir );

	return 1;
}

sub create_markdown
{
	my $text = markdown(shift);

	return $text;
}

sub create_statistics
{
	my $c = shift;

	my $data = shift;
	my $text = <<EOF;

## Statistics for $data->{agency}

EOF

	$text .= <<EOF;
### missing routes

EOF
	for ( @{ $data->{missing_routes} } ) {
		$text .= <<EOF;
 * $_->{route_type} $_->{route_short_name} ($_->{route_id}) [$_->{count}]
EOF
	}

	$text .= <<EOF;
### missing stops

EOF
	for ( @{ $data->{missing_stops} } ) {
		$text .= <<EOF;
 * $_->{route_id}/$_->{route_short_name}: $_->{trip_id} $_->{stop_name} ($_->{stop_code}) [$_->{count}]
EOF
	}

	$text .= <<EOF;
### unused routes

EOF
	for ( @{ $data->{unused_routes} } ) {
		$text .= <<EOF;
 * $_->{route_type} $_->{route_short_name}
EOF
	}

	$text .= <<EOF;
### unused trips

EOF
	for ( @{ $data->{unused_variants} } ) {
		$text .= <<EOF;
 * $_->{route_type} $_->{route_short_name}: $_->{trip_relation}
EOF
	}

	$text .= <<EOF;
### unused stops

EOF
	for ( @{ $data->{unused_stop} } ) {
		$text .= <<EOF;
 * $_->{route_type} $_->{route_short_name}: $_->{trip_relation} $_->{stop_name} $_->{stop_osm_entity}
EOF
	}

	$text .= <<EOF;
### wrong side of way/unlinked stops

EOF
	for ( @{ $data->{unlinked_stops} } ) {
		$text .= <<EOF;
 * $_->{route_type} $_->{route_short_name}: $_->{trip_relation} $_->{stop_name} $_->{stop_osm_entity}
EOF
	}

	# XXX: non-matching name

	return markdown($text),;
}

1;

=head1 COPYRIGHT

Copyright (c) 2008-2011 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
