package HuGTFS::FeedManager;

use 5.14.0;
use utf8;
use strict;
use warnings;

use Mouse::Role;

=head1 NAME

HuGTFS::FeedManager - HuGTFS feed manager for download + parsing data

=head1 SYNOPSIS

	use HuGTFS::FeedManager;

=head1 REQUIRES

perl 5.14.0, Text::CSV::Envoded, Archive::ZIP, IO::File

=head1 EXPORTS

Nothing.

=head1 DESCRIPTION

A base class for feed managers. An implementor needs to provide C<download> and C<parse> methods.

=head1 PROPERTIES

=head2 automatic

Automatic (= deploy) usage: the feed manager should set the appropriate defaults.

=cut

has 'automatic' => (
	is      => 'rw',
	isa     => 'Bool',
	default => 0,
);

=head2 force

Should things be forced?

=cut

has 'force' => (
	is      => 'rw',
	isa     => 'Bool',
	default => 0,
);

=head2 osm_file

Location of the OSM file.

=cut

has 'osm_file' => (
	is       => 'ro',
	isa      => 'Str',
	required => 1,
);

=head2 reference_url

Base url where the reference data in C<data_directory> will be copeid.
May be used for links in the gtfs data.

=cut

has 'reference_url' => (
	is       => 'ro',
	isa      => 'Str',
	required => 1,
);

=head2 directory

Base directory for the feed.

=cut

has 'directory' => (
	is       => 'ro',
	isa      => 'Str',
	required => 1,
);

=head2 data_directory

Data directory for the feed.

=cut

has 'data_directory' => (
	is      => 'ro',
	isa     => 'Str',
	lazy    => 1,
	builder => '_build_data_directory',
);

sub _build_data_directory
{
	my $self = shift;

	return $self->directory . '/data';
}

=head2 timetable_directory

GTFS directory for the feed.

=cut

has 'timetable_directory' => (
	is      => 'ro',
	isa     => 'Str',
	lazy    => 1,
	builder => '_build_timetable_directory',
);

sub _build_timetable_directory
{
	my $self = shift;

	return $self->directory . '/timetables';
}


=head2 gtfs_directory

GTFS directory for the feed.

=cut

has 'gtfs_directory' => (
	is      => 'ro',
	isa     => 'Str',
	lazy    => 1,
	builder => '_build_gtfs_directory',
);

sub _build_gtfs_directory
{
	my $self = shift;

	return $self->directory . '/gtfs';
}

=head2 options

FeedManager options provided in config.yml

=cut

has 'options' => (
	is      => 'rw',
);

=head1 METHODS

=cut

=head2 new

Create a new instance of the feed manager.

=cut

=head2 download

Download the required files for parsing.

=cut

requires 'download';

=head2 parse

Parse the feed data.

=cut

requires 'parse';

1;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
