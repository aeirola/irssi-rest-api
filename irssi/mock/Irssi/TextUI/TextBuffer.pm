package Irssi::TextUI::TextBuffer;
# https://github.com/shabble/irssi-docs/wiki/Textbuffer
# https://github.com/shabble/irssi-docs/blob/master/Irssi/TextUI/TextBuffer.pod

use Irssi::TextUI::Line;

sub new {
	my $class = shift;
	my %args = @_;

	my $cur_line;
	my $prev_line;
	for my $line (@{$args{lines}}) {
		$prev_line = $cur_line;
		$cur_line = Irssi::TextUI::Line->new('time' => @$line[0], 'text' => @$line[1], 'prev' => $prev_line);
		$prev_line->{_next} = $cur_line;
	}

	my $self = bless {
		cur_line => $cur_line
		}, $class;
	return $self;
}

sub add_line {
	my ($self, $text) = @_;
	my $prev_line = $self->{cur_line};
	my $prev_time = $prev_line->{info}->{time};
	my $cur_line =  Irssi::TextUI::Line->new('text' => $text, 'time' => $prev_time+1, 'prev' => $cur_line);
	$prev_line->{_next} = $cur_line;
 	$self->{cur_line} = $cur_line;
}

1;
