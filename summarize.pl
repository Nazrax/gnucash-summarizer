#!/usr/bin/perl

use strict;
use warnings;

use IO::Uncompress::Gunzip;
use Time::Local;
use XML::Simple;

use Data::Dumper;

our ($start, $end);
{
    my (undef, undef, undef, undef, $month, $year) = localtime(time);
    $start = timelocal(0, 0, 0, 1, $month-1, $year-1);
    $end = timelocal(0, 0, 0, 1, $month-1, $year);
}

my @patterns;
open IH, "patterns.txt" or die;
@patterns = <IH>;
close IH;

foreach (@patterns) {
    chomp;
}

my $z = new IO::Uncompress::Gunzip "finance2" or die;
my $xml = XMLin($z) or die;

my $transactions = $xml->{'gnc:book'}{'gnc:transaction'};
my $accounts = $xml->{'gnc:book'}{'gnc:account'};
$xml->{'gnc:book'}{'gnc:transaction'} = [];
$xml->{'gnc:book'}{'gnc:account'} = [];

my %accounts;
for my $account (@$accounts) {
    my $id = $account->{'act:id'}{content};
    my $name = $account->{'act:name'};
    my $type = $account->{'act:type'};

    my $parent;
    if (defined $account->{'act:parent'}) {
	$parent = $account->{'act:parent'}{content};
    }

    $accounts{$id} = {parent => $parent, type => $type, id => $id, name => $name};
}

my (%amounts, %income, %months, %mins, %maxes);
for my $tx (@$transactions) {
    my $rawDate = $tx->{'trn:date-posted'}{'ts:date'};
    my ($year, $month, $day) = ($rawDate =~ /^(\d{4})-(\d{2})-(\d{2}) \d{2}:\d{2}:\d{2} -?\d{4}$/);
    die "Unknown date format '$rawDate'\n" unless defined $day;
    my $date = timelocal(0, 0, 0, $day, $month-1, $year);
    my $shortDate = sprintf "%4d / %02d", $year, $month;
    $income{$shortDate} //= 0;

    if ($date >= $start && $date < $end) {
	for my $split (@{$tx->{'trn:splits'}{'trn:split'}}) {
	    my $acctId = $split->{'split:account'}{content};
	    my $fullAcctName = acctName($acctId);
            my $splitId = $$split{'split:id'}{content};

	    my $rawValue = $split->{'split:value'};
	    my ($undividedValue) = ($rawValue =~ m|^(-?\d+)/100$|);
	    die "Unknown raw value: '$rawValue'\n" unless defined $undividedValue;
	    my $value = $undividedValue / 100;

            if ($fullAcctName =~ /^Income/) {
              $value *= -1;
              $income{$shortDate} += $value;
              next;
            }

	    my $acctName = processIgnores($fullAcctName);
	    next if !defined $acctName;

	    $amounts{$acctName} //= {};
	    $amounts{$acctName}{$shortDate} //= 0;
	    $amounts{$acctName}{$shortDate} += $value;
	    $months{$shortDate} = 1;
	}
    }
}

print join(',', 'Account Name', 'Average', sort(keys(%months)), 'Total', 'Swing') . "\n";

my %monthlyTotals;
my $avgTotal = 0;
my $totalTotal = 0;

for my $acctName (sort keys %amounts) {
    print "$acctName,";
    my @values;
    my $count = 0;
    my $sum = 0;
    foreach my $shortDate (sort keys %months) {
	my $value = $amounts{$acctName}{$shortDate};
	$value //= 0;
	push @values, sprintf("\$%.2f", $value);
	$sum += $value;
	$count++;
        $monthlyTotals{$shortDate} //= 0;
        $monthlyTotals{$shortDate} += $value;
        $mins{$acctName} = $value if !defined $mins{$acctName} || $mins{$acctName} > $value;
        $maxes{$acctName} = $value if !defined $maxes{$acctName} || $maxes{$acctName} < $value;
    }
    my $avg = sprintf("\$%.2f", ($sum / $count));
    $avgTotal += ($sum / $count);
    $totalTotal += $sum;
    my $swing = sprintf("\$%.2f", ($maxes{$acctName} - $mins{$acctName}));
    print join(',', $avg, @values, '$' . $sum, $swing) . "\n";
}

my (@monthlyTotals, @deficits, @incomes);
my $totalIncome = 0;
foreach my $shortDate (sort keys %months) {
  push @monthlyTotals, sprintf("\$%.2f", $monthlyTotals{$shortDate});
  push @incomes, $income{$shortDate};
  push @deficits, sprintf("\$%.2f", $income{$shortDate} - $monthlyTotals{$shortDate});
  $totalIncome += $income{$shortDate};
}

my $avgIncome = $totalIncome / scalar(keys %months);
print "\n";
print join(',', '', sprintf("\$%.2f", $avgIncome), @incomes, $totalIncome) . "\n";
print join(',', '', sprintf("\$%.2f", $avgTotal), @monthlyTotals, $totalTotal) . "\n";
print join(',', '', sprintf("\$%.2f", $avgIncome-$avgTotal), @deficits, sprintf("\$%.f", $totalIncome-$totalTotal)) . "\n";
#my $rowCount = scalar(keys %amounts) + 1;
#my @sums;
#foreach my $column (qw/B C D E F G H I J K L M N/) {
# push @sums, "=sum(${column}2:${column}$rowCount)";
#}
#print join(',', '', @sums) . "\n";


sub processIgnores {
    my $acctName = shift;

    if (!defined $acctName) {
	return;
    }
    foreach my $pattern (@patterns) {
	if ($acctName =~ /^$pattern$/) {
	    my ($n) = ($acctName =~ /^(.*):[^:]+$/);
	    return processIgnores($n);
	}
    }
    return $acctName;
}

sub acctName {
    my $id = shift;
    my $account = $accounts{$id};
    if (defined $account->{fullname}) {
	return $account->{fullname};
    } else {
	if (defined $account->{parent}) {
	    my $parentName = acctName($account->{parent});
	    if (defined $parentName) {
		$account->{fullname} = $parentName . ":" . $account->{name};
	    } else {
		$account->{fullname} = $account->{name};
	    }
	} else {
	    return undef;
	}
    }
}
