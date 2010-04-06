#!/usr/bin/perl -w
use strict;

=head1 NAME

logfilebayes.pl - Bayesian log file reader

=head1 SYNOPSYS

C<logfilebayes.pl --database=>I<dbpath> C<--learn=>I<severity> I<text>

C<logfilebayes.pl --database=>I<dbpath> C<--rate> I<text>

C<logfilebayes.pl --database=>I<dbpath> --bookmark=>I<bookmarkfile> --logfile=>I<logfile> [--explain] [--autolearn]

=head1 OPTIONS

=over 4

=item C<--database=>I<dbpath>

This is the only required argument. It is the path to the stored
Bayesian database. If it does not already exist, the database is created.
It is best not to share databases; no locking is performed.

=item C<--learn=>I<severity>

Used to invoke manual training mode. The severity must be one of:

=over 8 

=item ignore

=item warning

=item normal

=item minor

=item major

=item critical

=back

It is case insensitive. The remaining command-line arguments are assumed
to be words which should be associated with the given severity.

Note that this is not guaranteed to mean that future references to those
words will force that severity -- it just increases the likelihood.

It does make sense to run the same C<--learn> several times if you want
to strongly encourage C<logfilebayes.pl> to use that severity.

=item C<--rate>

The remaining command-line arguments are assumed to be words in a
sentence.  This will report what severity level would have been
reported if that sentence had been found in a logfile.

=item C<--bookmark=>I<bookmarkfile>

Must be used in conjunction with C<--logfile>. C<logfilebayes.pl> only reads
the logfile from where it left off last time. The previous position is stored
in plain text in the file I<bookmarkfile>.

No locking is done on the bookmark file.

=item C<--logfile=>I<logfile>

Must be used in conjunction with C<--bookmark>. Read the given I<logfile>
from the last-read position (read out of the bookmark file).

If this is the first time C<logfilebayes.pl> has been run, it writes
the current size of I<logfile> into the bookmark file and then exits.

Otherwise, take each new line of text from I<logfile>, rate it according
to the data found in the I<dbpath> and report what tag is most likely to 
be appropriate for that line.

The output is:

  rating<TAB><TAB>text<TAB>most significant word<TAB>next most<TAB>next

=item C<--explain>

Provide verbose output about each line of output.

=item C<--autolearn>

Feed each line of logfile text back into the rating engine for
learning after a "most likely" tag has been already found. In this
way, it will learn more words commonly found in (critical, ignore,
etc.) messages.


=back

=cut

#use Getopt::Long 2.33; # one day when OVO ships with a modern Getopt::Long
use Getopt::Long;
use English;
use Pod::Usage;
use Fcntl qw(SEEK_SET);

my $learn = undef;
my $database = undef;
my $rate = 1;
my $bookmark = undef;
my $logfile = undef;
my $explain = undef;
my $autolearn = undef;
my $message_text;

Getopt::Long::GetOptions(
			 'learn:s' => \$learn,
			 'database:s' => \$database,
			 'rate!' => \$rate,
			 'bookmark:s' => \$bookmark,
			 'logfile:s' => \$logfile,
			 'explain!' => \$explain,
			 'autolearn' => \$autolearn
)  or pod2usage(2);

die "Must specify --database. Exiting\n" unless defined $database;

my $nb;

if (! -e $database) {
 $nb = Algorithm::NaiveBayes->new(purge=>0);
 # initialise it with obvious defaults
 my $word;
 foreach $word (qw{can't couldn't didn't isn't failed missing lost error}) {
   $nb->add_instance(attributes => { $word => 1 },
                     label => 'critical');
 }
 foreach $word (qw{warning minor major critical}) {
   $nb->add_instance(attributes => { $word => 1 },
                     label => $word);
 }
 foreach $word (qw{notice info}) {
   $nb->add_instance(attributes => { $word => 1 },
                     label => 'ignore');
 }
 $nb->train();
 $nb->save_state($database);
} elsif (! -r $database) {
  die "Cannot read $database. Exiting\n";
} else {
 $nb = Algorithm::NaiveBayes->restore_state($database);
} 

sub text_to_words {
 my $message_text = shift;
 my @words = split(/[\s,;]+/,$message_text);
 while ($words[0] =~ /^\{.*\}/) { shift @words; }
 my $i;
WORD:
 for($i=0;$i<=$#words;$i++) {
   next WORD if ($words[$i] =~ /^[A-Z]:/);
   $words[$i] =~ s/[.:]*$//;
   $words[$i] = lc $words[$i];
 } 
 return @words
};

die "Logfile not specified" if defined $bookmark and not defined $logfile;
die "Bookmark not specified" if not defined $bookmark and defined $logfile;

my @stat_struct;
if (defined $bookmark and defined $logfile) {
  open(LOGFILE,$logfile) || die "Could not read $logfile";
  # should lock bookmark file for reading. Probably don't need to
  # lock logfile for reading... or do we?
  my $position;
  if (!open(BOOKMARK,$bookmark)) {
    @stat_struct = stat $logfile; 
    $position = $stat_struct[7];
  } else {
    $position = <BOOKMARK>;
    chomp $position;
    close(BOOKMARK);
    if ($position !~ /^\d+$/) { $position = 0; } # or should I reset to the end?
  }
  @stat_struct = stat $logfile;
  if ($stat_struct[7] < $position) {
      $position = $stat_struct[2];
  }
  seek(LOGFILE,$position,SEEK_SET);
  $position = tell LOGFILE;
  while ($message_text = <LOGFILE>) {
    my @message_words =  &text_to_words($message_text);
    my $word;
    my %weighting_hash;
    foreach $word (@message_words) { $weighting_hash{$word} = 1;}
    my $result = $nb->predict(attributes => \%weighting_hash);
    my $best_score = 0.0;
    my $best = "";
    my $each_result;
    foreach $each_result (keys %$result) {
      if ($result->{$each_result} > $best_score) {
        $best = $each_result;
        $best_score = $result->{$each_result};
      }
      print STDERR "Score for \U$each_result\E is $result->{$each_result}.\n"
        if $explain;
    }
    my %word_effects;
    foreach $word (@message_words) {
      $result = $nb->predict(attributes => { $word => 1 });
      print STDERR "  '$word' contributed $result->{$best}\n" if $explain;
      $word_effects{$word} = $result->{$best};
    }
    my @important_words = sort {  $word_effects{$b} <=> $word_effects{$a} }
                                                    (keys %word_effects);
    @important_words = @important_words[0..2];
    @important_words = grep($word_effects{$_} > 0.1,@important_words);
    my $pretext = $#important_words == -1 ? "" : 
      "{".join("} {",@important_words)."} ";
    print "\U$best\E\t\t$message_text\t$pretext\n";
    if ($autolearn) {
      $nb->add_instance(attributes => \%weighting_hash,label => $best);
      $nb->train();
    }
  }
  # locking needed here?
  open(BOOKMARK,">$bookmark");
  $position = tell (LOGFILE);
  print BOOKMARK "$position\n";
  close(BOOKMARK);
  $nb->save_state($database);
  exit(0);
}

if (defined $learn) {
  pod2usage(2) unless $learn =~ /ignore|warning|normal|minor|major|critical/i;
  $message_text = join(" ",@ARGV);
  my @message_words;
  $message_text =~ s/\s*$//;
  @message_words = &text_to_words($message_text);
  my $word;
  my %weighting_hash;
  foreach $word (@message_words) { $weighting_hash{$word} = 1;}
  $nb->add_instance(attributes => \%weighting_hash,label => $learn);
  $nb->train();
  $nb->save_state($database);
}

if ($rate || $learn) {
  $message_text = join(" ",@ARGV);
   my @message_words =  &text_to_words($message_text);
   my $word;
   my %weighting_hash;
   my $word_result;
   my $label;
   foreach $word (@message_words) {
     $word_result = $nb->predict(attributes => { $word => 1 });
     foreach $label (keys %$word_result) {
       print "     '$word' contributed $word_result->{$label} to $label\n";
     }
   }
   foreach $word (@message_words) { $weighting_hash{$word} = 1;}
   my $result = $nb->predict(attributes => \%weighting_hash);
   foreach $label (keys %$result) {
    print "  $label=".$result->{$label}."\n";
   }
}




######################################################################
# From here on is code from Ken Williams, ken@mathforum.org. You can
# find it on CPAN.

package Algorithm::NaiveBayes::Util;

use strict;
use base qw(Exporter);
use vars qw(@EXPORT_OK);
@EXPORT_OK = qw(sum sum_hash max variance add_hash rescale);

use List::Util qw(max sum);

sub sum_hash {
  my $href = shift;
  return sum(values %$href);
}

sub variance {
  my $array = shift;
  return 0 unless @$array > 1;
  my $mean = @_ ? shift : sum($array) / @$array;

  my $var = 0;
  $var += ($_ - $mean)**2 foreach @$array;
  return $var / (@$array - 1);
}

sub add_hash {
  my ($first, $second) = @_;
  foreach my $k (keys %$second) {
    $first->{$k} += $second->{$k};
  }
}

sub rescale {
  my ($scores) = @_;

  # Scale everything back to a reasonable area in logspace (near zero), un-loggify, and normalize
  my $total = 0;
  my $max = max(values %$scores);
  foreach (values %$scores) {
    $_ = exp($_ - $max);
    $total += $_**2;
  }
  $total = sqrt($total);
  foreach (values %$scores) {
    $_ /= $total;
  }
}

1;


package Main;

package Algorithm::NaiveBayes;

use strict;
use Storable;

use vars qw($VERSION);
$VERSION = '0.04';

sub new {
  my $package = shift;
  my $self = bless {
	      version => $VERSION,
	      purge => 1,
	      model_type => 'Frequency',
	      @_,
	      instances => 0,
	      training_data => {},
	     }, $package;
  
  if ($package eq __PACKAGE__) {
    # Bless into the proper subclass
    return $self->_load_model_class->new(@_);
  }
  
  return bless $self, $package;
}

sub _load_model_class {
  my $self = shift;
  die "model_class cannot be set to " . __PACKAGE__ if ($self->{model_class}||'') eq __PACKAGE__;
  my $package = $self->{model_class} || __PACKAGE__ . "::Model::" . $self->{model_type};
  unless ($package->can('new')) {
    eval "use $package";
    die $@ if $@;
  }
  return $package;
}

sub save_state {
  my ($self, $path) = @_;
  Storable::nstore($self, $path);
}

sub restore_state {
  my ($pkg, $path) = @_;
  my $self = Storable::retrieve($path)
    or die "Can't restore state from $path: $!";
  $self->_load_model_class;
  return $self;
}

sub add_instance {
  my ($self, %params) = @_;
  for ('attributes', 'label') {
    die "Missing required '$_' parameter" unless exists $params{$_};
  }
  for ($params{label}) {
    $_ = [$_] unless ref;
    @{$self->{labels}}{@$_} = ();
  }
  
  $self->{instances}++;
  $self->do_add_instance($params{attributes}, $params{label}, $self->{training_data});
}

sub labels { keys %{ $_[0]->{labels} } }
sub instances  { $_[0]->{instances} }
sub training_data { $_[0]->{training_data} }

sub train {
  my $self = shift;
  $self->{model} = $self->do_train($self->{training_data});
  $self->do_purge if $self->purge;
}

sub do_purge {
  my $self = shift;
  delete $self->{training_data};
}

sub purge {
  my $self = shift;
  $self->{purge} = shift if @_;
  return $self->{purge};
}

sub predict {
  my ($self, %params) = @_;
  my $newattrs = $params{attributes} or die "Missing 'attributes' parameter for predict()";
  return $self->do_predict($self->{model}, $newattrs);
}

1;

package Main;

1;

package Algorithm::NaiveBayes::Model::Frequency;

use strict;
#use Algorithm::NaiveBayes::Util qw(sum_hash add_hash max rescale);
import Algorithm::NaiveBayes::Util qw(sum_hash add_hash max rescale);
use base qw(Algorithm::NaiveBayes);

sub new {
  my $self = shift()->SUPER::new(@_);
  $self->training_data->{attributes} = {};
  $self->training_data->{labels} = {};
  return $self;
}

sub do_add_instance {
  my ($self, $attributes, $labels, $training_data) = @_;
  Algorithm::NaiveBayes::Util::add_hash($training_data->{attributes}, $attributes);
  
  my $mylabels = $training_data->{labels};
  foreach my $label ( @$labels ) {
    $mylabels->{$label}{count}++;
    Algorithm::NaiveBayes::Util::add_hash($mylabels->{$label}{attributes} ||= {}, $attributes);
  }
}

sub do_train {
  my ($self, $training_data) = @_;
  my $m = {};
  
  my $instances = $self->instances;
  my $labels = $training_data->{labels};
  $m->{attributes} = $training_data->{attributes};
  my $vocab_size = keys %{ $m->{attributes} };
  
  # Calculate the log-probabilities for each category
  foreach my $label ($self->labels) {
    $m->{prior_probs}{$label} = log($labels->{$label}{count} / $instances);
    
    # Count the number of tokens in this cat
    my $label_tokens = Algorithm::NaiveBayes::Util::sum_hash($labels->{$label}{attributes});
    
    # Compute a smoothing term so P(word|cat)==0 can be avoided
    $m->{smoother}{$label} = -log($label_tokens + $vocab_size);
    
    # P(attr|label) = $count/$label_tokens                         (simple)
    # P(attr|label) = ($count + 1)/($label_tokens + $vocab_size)   (with smoothing)
    # log P(attr|label) = log($count + 1) - log($label_tokens + $vocab_size)
    
    my $denominator = log($label_tokens + $vocab_size);
    
    while (my ($attribute, $count) = each %{ $labels->{$label}{attributes} }) {
      $m->{probs}{$label}{$attribute} = log($count + 1) - $denominator;
    }
  }
  return $m;
}

sub do_predict {
  my ($self, $m, $newattrs) = @_;
  
  # Note that we're using the log(prob) here.  That's why we add instead of multiply.
  
  my %scores = %{$m->{prior_probs}};
  while (my ($feature, $value) = each %$newattrs) {
    next unless exists $m->{attributes}{$feature};  # Ignore totally unseen features
    while (my ($label, $attributes) = each %{$m->{probs}}) {
      $scores{$label} += ($attributes->{$feature} || $m->{smoother}{$label})*$value;   # P($feature|$label)**$value
    }
  }
  
  Algorithm::NaiveBayes::Util::rescale(\%scores);

  return \%scores;
}

1;


package Main;


