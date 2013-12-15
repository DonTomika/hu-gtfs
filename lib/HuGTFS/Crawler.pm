
=head1 NAME

HuGTFS::Crawler - A simple crawler for use with HuGTFS

=head1 SYNOPSIS

	use HuGTFS:Crawler;

=head1 REQUIRES

perl 5.14.0, WWW::Mechanize, LWP::ConnCache

=head1 EXPORTS

Nothing.

=head1 DESCRIPTION

A simple crawler for use with HuGTFS. Keeps track of visited urls,
and modifications times to avoid downloading the same file multiple
times.

=head1 METHODS

=cut

package HuGTFS::Crawler;

use 5.14.0;
use utf8;
use strict;
use warnings qw/ all /;

use DateTime;
use Digest::MD5 qw(md5_hex);
use LWP::ConnCache;
use Encode qw(encode_utf8);
use File::Spec::Functions;
use WWW::Mechanize;
use IO::File;
use Log::Log4perl;
use HuGTFS::Util;

=head2 crawl $class, $urls, $dir, $further_urls, $cleanup, $options

Starts a crawl with the specified parameters.

=over 2

=item $urls

The urls to crawl.

=item $dir

The directory to save files to.

=item $further_urls->($content, $mech, $mech->url) -> (new params for C<crawl>)

A function to determine what (new) urls should be crawled from
the contents of the crawled url.

The returned array is the parameters with which to call C<crawl>
again. C<$options> is automatically copied to the new crawler.

A list of visited files is kept to avoid endless recursions.

=item $cleanup->($content, $mech, $mech->url) -> $new_content

A function to cleanup the returned text data.

=item options

=over 3

=item name_file

A function for naming files. By default all downloaded files are saved
into a file based on the hash of it's url.

=item proxy

Should a proxy be used for requests?

=item force

Force the downloading of data, even if cached?

=item binary

Are the files binary? (or should calling C<$cleanup> be avoided.)

=item sleep

Sleep interval in seconds between requests.

=back

=cut

sub crawl
{
	my ( $class, $urls, $dir, $further_urls, $cleanup, $options ) = @_;
	my ( $updated, $files ) = ( 0, $options->{_files} || {} );
	my $log = Log::Log4perl::get_logger(__PACKAGE__);

	my $mech = WWW::Mechanize->new();
	if ( $options->{proxy} ) {
		$mech->proxy( ['http'], 'socks://localhost:9050' );
	}
	unless( $options->{anonymous} ) {
		$mech->agent('HuGTFS Timetable Downloader (email: contact@transit.flaktack.net)');
	}
	$mech->conn_cache( LWP::ConnCache->new );

	$log->info( "Starting crawl for " . scalar @$urls . " urls" );

	local $| = 1;

	mkdir($dir) unless -d $dir;

	if ( $options->{force} ) {
		unlink <$dir/*>;
	}

	$urls = [
		map {
			$_ =~ s/#.*$//g;
			$_;
			}
			map {
			(ref)
				? ( (ref) =~ m/^WWW::Mechanize::(?:Image|Link)$/
				? "" . $_->url_abs->abs . ""
				: "$_" )
				: $_
			} @$urls
	];

	foreach my $url (@$urls) {
		my ( $ext, $file, $filename, $content )
			= ( ( $url =~ m/^[^?]*\.([a-z0-9]+)$/i )[0] || 'html', IO::File->new() );

		if ( $#{ [ grep { $_ eq $url } values %$files ] } >= 0 ) {
			$log->debug("Skipped visited url: $url");
			next;    # Already visited
		}

		if ($further_urls) {
			$filename = catfile( $dir, 'list_' . md5_hex($url) . '.html' );
		}
		else {
			$filename = catfile( $dir, 'file_' . md5_hex($url) . ".$ext" );
		}
		if ( $options && $options->{name_file} ) {
			my $n = $options->{name_file}->( $url, $filename );
			$filename = catfile( $dir, $n ) if $n;
		}

		eval {
			if ( -f $filename )
			{
				$log->info("Downloading [cached] $url >> $filename");
				my $date = DateTime->from_epoch( epoch => ( ( stat $file )[9] ) );
				$mech->get( $url,
					'If-Modified-Since' => $date->strftime('%a, %d %b %Y %H:%M:%S GMT') );
			}
			else {
				$log->info("Downloading $url >> $filename");
				$mech->get($url);
			}
		};
		my $binary = ( $options->{binary} || $mech->content_type !~ m{^text/} );

		if ( $mech->status eq '403' ) {    # FORBIDDEN
			$log->logconfess("Forbidden: $url");
		}

		if ($@) {
			$log->warn("Failed to download $url: $@");
		}

		if ($further_urls) {
			my @crawlee = ();

			if ( $mech->status eq '304' ) {    # NOT-MODIFIED
				$log->debug("Using cache [304] for $url");
			}
			else {

				if ($cleanup) {
					$content = $cleanup->( $mech->content, $mech, $url );
				}
				else {
					$content = $mech->content;
				}

				if ( $mech->status eq '200' && -f $filename ) {
					my $file_old;
					if ($binary) {
						open( $file_old, '<', $filename )
							or $log->logconfess("Can't open <<$filename>>: $!");
						binmode($file_old);
					}
					else {
						open( $file_old, '<:utf8', $filename )
							or $log->logconfess("Can't open <<$filename>>: $!");
					}

					local $/ = undef;

					if ( md5_hex( encode_utf8($content) ) eq md5_hex( encode_utf8(<$file_old>) )
						)
					{
						$log->debug("Using cache [MD5] for $url");
						goto FINIANEW;
					}
					$log->debug("Ignoring cache for $url");
				}

				unlink $filename;
				if ($binary) {
					open( $file, '>', $filename );
					binmode($file);
				}
				else {
					open( $file, '>:utf8', $filename );
				}
				$file->print($content);
				$file->close();
			}
		FINIANEW:

			$files->{$filename} = $url;

			@crawlee = $further_urls->( $content, $mech, $url );

			if ( $#crawlee > 0 ) {
				$crawlee[4]->{_files} = $files;
				$crawlee[1] = $dir unless $crawlee[1];

				%{ $crawlee[4] } = ( %$options, %{ $crawlee[4] } );

				$updated = $class->crawl(@crawlee) || $updated;
			}
			else {
				$log->warn("No further urls for $url");
			}
		}
		else {
			if ( $mech->status eq '304' ) {    # NOT-MODIFIED
				$log->debug("Using cache [304] for $url");
				goto FINI;
			}

			if ($cleanup) {
				$content = $cleanup->( $mech->content, $mech, $url );
			}
			else {
				$content = $mech->content;
			}

			if ( $mech->status eq '200' && -f $filename ) {
				my $file_old;
				if ($binary) {
					open( $file_old, '<', $filename )
						or $log->error("Can't open <<$filename>>: $!");
					binmode($file_old);
				}
				else {
					open( $file_old, '<:utf8', $filename )
						or $log->error("Can't open <<$filename>>: $!");
				}

				local $/ = undef;

				if ( md5_hex( encode_utf8($content) ) eq md5_hex( encode_utf8(<$file_old>) ) ) {
					$log->debug("Using cache [MD5] for $url");
					goto FINI;
				}
				$log->debug("Ignoring cache for $url");
			}

			unlink $filename;
			if ($binary) {
				open( $file, '>', $filename );
				binmode($file);
			}
			else {
				open( $file, '>:utf8', $filename );
			}
			$file->print($content);
			$file->close();
			$updated = 1;
		}

	FINI:
		$files->{$filename} = $url;

		sleep $options->{sleep} if $options->{sleep};
	}

	unless ( $options->{_files} ) {
		foreach my $file (<$dir/*.*>) {
			if ( !$files->{$file} && $file ne catfile( $dir, 'map.txt' ) ) {
				$log->debug("Removed unneded <$file>");
				# unlink $file;
				$updated = 1;
			}
		}
	}

	if ( $updated && !$options->{_files} ) {
		open( my $file, '>:utf8', catfile( $dir, 'map.txt' ) );

		foreach my $key ( keys %$files ) {
			$file->print( $key . ' ' . $files->{$key} . "\n" );
		}

		$file->close();
	}

	return $updated;
}

1 + 1 == 2;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
