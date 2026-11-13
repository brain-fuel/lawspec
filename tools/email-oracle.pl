#!/usr/bin/env perl
# The differential oracle for LawSpec's `email` format (src/LawSpec/Formats.hs):
# Paul Warren's Mail::RFC822::Address 0.3, which is not part of this repository.
#
#   perl tools/email-oracle.pl <path to Address.pm> < inputs > verdicts
#
# Each input line is a text as hexadecimal code points separated by spaces
# (an empty line is the empty text). Each output line repeats the input and
# adds two verdicts, tab separated:
#
#   regex   the module's regex alone, as valid() applies it: m/^$rfc822re$/s
#   valid   the module's valid(), which first replaces comments with a space
#
# Every text is given to the module as a character string, so Perl applies
# Unicode rules to \s. The module's regexes backtrack, and on some texts for
# longer than anyone will wait: a verdict not reached in two seconds is
# printed as `?`, and the text is left out of the record. `lawspec-dev
# email-vectors` runs this script; nothing else does, and LawSpec's tests
# replay the recorded verdicts without Perl.
use strict;
use warnings;
use POSIX qw(SIGALRM);

my $module = shift @ARGV or die "usage: email-oracle.pl <path to Address.pm>\n";
require $module;
my $rfc822re = Mail::RFC822::Address::make_rfc822re();

# Perl defers an ordinary signal handler until the running match returns, so
# the alarm is installed with sigaction, which interrupts it.
POSIX::sigaction(SIGALRM, POSIX::SigAction->new(sub { die "timeout\n" }))
    or die "cannot install the alarm handler: $!\n";

sub verdict {
    my ($check) = @_;
    my $answer = eval { alarm 2; my $r = $check->() ? 1 : 0; alarm 0; $r };
    alarm 0;
    return defined $answer ? $answer : '?';
}

while (my $line = <STDIN>) {
    chomp $line;
    my $text = join '', map { chr hex } split ' ', $line;
    utf8::upgrade($text);
    my $regex = verdict(sub { $text =~ m/^$rfc822re$/s });
    my $valid = verdict(sub { Mail::RFC822::Address::valid($text) });
    print "$line\t$regex\t$valid\n";
}
