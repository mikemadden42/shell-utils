#!/usr/bin/env perl
use v5.34;
use warnings;

use Time::Local qw(timelocal_posix);

sub fail {
    print STDERR "Error: $_[0]\n";
    exit 1;
}

# Replace with your desired date in the past (YYYY-MM-DD format)
my $past_date = '2020-07-06';

# Get timestamps in seconds since epoch for today and past date. Like GNU
# date --date, a bare date means local midnight; timelocal does that without
# GNU date, which macOS lacks.
my ( $year, $month, $day ) = $past_date =~ /^(\d{4})-(\d{2})-(\d{2})\z/
    or fail("invalid date '$past_date', expected YYYY-MM-DD.");
my $now_seconds = time;
my $past_seconds =
    eval { timelocal_posix( 0, 0, 0, $day, $month - 1, $year - 1900 ); }
    // fail("invalid date '$past_date'.");

# Calculate the difference in seconds
my $difference_seconds = $now_seconds - $past_seconds;

# Convert the difference to days (consider rounding behavior)
my $number_of_days = int( $difference_seconds / ( 60 * 60 * 24 ) );

say "There are $number_of_days days between today and '$past_date'.";
