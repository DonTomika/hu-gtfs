package HuGTFS::FeedManagerConvert;

use 5.14.0;
use utf8;
use strict;
use warnings;

use Mouse::Role;

=head1 NAME

HuGTFS::FeedManager - HuGTFS feed manager for download + parsing data

=head1 SYNOPSIS

	use HuGTFS::FeedManagerConvert;

=head1 DESCRIPTION

A base class for feed managers, which need timetable conversion.
An implementor needs to provide a C<convert> method.

=head1 METHODS

=head2 convert

Convert donwloaded timetables into static ones.

=cut

requires 'convert';

1;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
