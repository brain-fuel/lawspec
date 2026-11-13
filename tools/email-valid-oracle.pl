#!/usr/bin/env perl
# The differential oracle for LawSpec's `email` format (src/LawSpec/Formats.hs):
# Email::Valid 1.204, which is not part of this repository. It needs
# Mail::Address (MailTools) installed.
#
#   perl tools/email-valid-oracle.pl <path to Email::Valid's lib directory> < inputs > verdicts
#
# Each input line is a text as hexadecimal code points separated by spaces
# (an empty line is the empty text). Each output line repeats the input and
# adds, tab separated, the verdict of
#
#   Email::Valid->address(-address => $text, -fqdn => 1, -allow_ip => 1,
#                         -localpart => 1, -mxcheck => 0, -tldcheck => 0,
#                         -fudge => 0, -local_rules => 0)
#
# which never uses the network: 1 when it returns an address, 0 when it
# returns nothing. A verdict not reached in two seconds is printed as `?`.
# `lawspec-dev email-vectors` runs this script; nothing else does, and
# LawSpec's tests replay the recorded verdicts without Perl.
use strict;
use warnings;
use POSIX qw(SIGALRM);

my $lib = shift @ARGV or die "usage: email-valid-oracle.pl <path to Email::Valid's lib directory>\n";
unshift @INC, $lib;
require Email::Valid;

# Mail::Address warns on stderr about texts it cannot parse; the verdict
# already says so.
local $SIG{__WARN__} = sub { };

POSIX::sigaction(SIGALRM, POSIX::SigAction->new(sub { die "timeout\n" }))
    or die "cannot install the alarm handler: $!\n";

while (my $line = <STDIN>) {
    chomp $line;
    my $text = join '', map { chr hex } split ' ', $line;
    utf8::upgrade($text);
    my $answer = eval {
        alarm 2;
        my $address = Email::Valid->address(
            -address => $text, -fqdn => 1, -allow_ip => 1, -localpart => 1,
            -mxcheck => 0, -tldcheck => 0, -fudge => 0, -local_rules => 0);
        alarm 0;
        defined $address ? 1 : 0;
    };
    alarm 0;
    print "$line\t" . (defined $answer ? $answer : '?') . "\n";
}
