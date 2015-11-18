package consoles::vnc_base;
use strict;
use base ('consoles::console');

use consoles::VNC;
use Time::HiRes qw(usleep gettimeofday);

use feature qw/say/;
use Data::Dumper qw(Dumper);
use Carp qw(confess cluck carp croak);

sub init() {
    my ($self) = @_;
    $self->{name} = 'vnc-base';
    $self->init_charmap;
}

sub select() {
}

sub activate() {
    my ($self, $testapi_console, $args) = @_;
    $self->connect_vnc($args);
    return $self->SUPER::activate($testapi_console, $args);
}

sub connect_vnc {
    my ($self, $args) = @_;

    CORE::say __FILE__.":".__LINE__.":".bmwqemu::pp($args);
    $self->{vnc} = consoles::VNC->new($args);
    # try to log in; this may fail a few times
    for my $i (1 .. 10) {
        my @connection_error;
        eval {
            local $SIG{__DIE__};
            $self->{vnc}->login();
        };
        if ($@) {
            push @connection_error, $@;
            if ($i > 7) {
                $self->close_pipes();
                die join("\n", @connection_error);
            }
            else {
                sleep 1;
            }
        }
        else {
            last;
        }
    }

    return $self->{vnc};
}

sub request_screen_update {
    my ($self) = @_;
    return unless $self->{vnc};
    # drain the VNC socket before polling for a new update
    $self->{vnc}->update_framebuffer();
    $self->{vnc}->send_update_request();
    return;
}

sub current_screen {
    my ($self) = @_;
    return unless $self->{vnc};

    unless ($self->{vnc}->_framebuffer) {
        # No _framebuffer yet.  First connect?  Tickle vnc server to
        # get it filled.
        $self->request_screen_update();
        # wait long enough, new Xvnc on tumbleweed choked on shorter
        # waits after first login

        # FIXME: should instead loop update_framebuffer until
        # _framebuffer in connect_vnc?  works for now.
        usleep(50_000);
    }

    $self->{vnc}->update_framebuffer();
    return unless $self->{vnc}->_framebuffer;
    return $self->{vnc}->_framebuffer;
}

sub close_pipes {
    my ($self) = @_;

    close($self->{vnc}->socket) if ($self->{vnc} && $self->{vnc}->socket);
    $self->{vnc} = undef;

    return $self->SUPER::close_pipes();
}

sub init_charmap {

    my ($self) = @_;

    ## charmap (like L => shift+l)
    # see http://en.wikipedia.org/wiki/IBM_PC_keyboard
    $self->{charmap} = {
        # minus is special as it splits key combinations
        "-" => "minus",
        # first line of US layout
        "~"  => "shift-`",
        "!"  => "shift-1",
        "@"  => "shift-2",
        "#"  => "shift-3",
        "\$" => "shift-4",
        "%"  => "shift-5",
        "^"  => "shift-6",
        "&"  => "shift-7",
        "*"  => "shift-8",
        "("  => "shift-9",
        ")"  => "shift-0",
        "_"  => "shift-minus",
        "+"  => "shift-=",

        # second line
        "{" => "shift-[",
        "}" => "shift-]",
        "|" => "shift-\\",

        # third line
        ":" => "shift-;",
        '"' => "shift-'",

        # fourth line
        "<" => "shift-,",
        ">" => "shift-.",
        '?' => "shift-/",

        "\t" => "tab",
        "\n" => "ret",
        "\b" => "backspace",

        "\e" => "esc"
    };
    for my $c ("A" .. "Z") {
        $self->{charmap}->{$c} = "shift-\L$c";
    }

    ## charmap end
}

sub map_letter {
    my ($self, $letter) = @_;
    return $self->{charmap}->{$letter} if $self->{charmap}->{$letter};
    return $letter;
}

sub type_string {
    my ($self, $args) = @_;

    # speed limit: 15bps.  VNC has key up and key down over the wire,
    # not whole key press events.  So with a faster pace, the vnc
    # server may think of contact bounces for repeating keys.
    my $seconds_per_keypress = 1 / 15;

    # further slow down if being asked for.
    # 250 = magic default from testapi.pm (FIXME: wouldn't undef just do?)

    # FIXME: the intended use of max_interval is the bootloader.  The
    # bootloader prompt drops characters when typing quickly.  This
    # problem mostly occurs in the bootloader.  Humans notice because
    # they look at the screen while typing.  So this loop should be
    # replaced by some true 'looking at the screen while typing',
    # e.g. waiting for no more screen updates 'in the right area'.
    # For now, just waiting is good enough: The slow-down only affects
    # the bootloader sequence.
    if (($args->{max_interval} // 250) < 250) {
        # according to 	  git grep "type_string.*, *[0-9]"  on
        #   https://github.com/os-autoinst/os-autoinst-distri-opensuse,
        # typical max_interval values are
        #   4ish:  veeery slow
        #   15ish: slow
        $seconds_per_keypress = $seconds_per_keypress + 1 / sqrt($args->{max_interval});
    }

    for my $letter (split("", $args->{text})) {
        $letter = $self->map_letter($letter);
        $self->{vnc}->send_mapped_key($letter);
        $self->{backend}->run_capture_loop(undef, $seconds_per_keypress, $seconds_per_keypress * .9);
    }
    return {};
}

sub send_key {
    my ($self, $args) = @_;

    bmwqemu::diag "send_mapped_key '" . $args->{key} . "'";
    # FIXME the max_interval logic from type_string should go here, no?
    # and really, the screen should be checked for settling after key press...
    $self->{vnc}->send_mapped_key($args->{key});
    $self->{backend}->run_capture_loop(undef, .2, .19);
    return {};
}

sub mouse_hide {
    my ($self, $args) = @_;

    $self->{mouse}->{x} = $self->{vnc}->width - 1;
    $self->{mouse}->{y} = $self->{vnc}->height - 1;

    my $border_offset = int($args->{border_offset});
    $self->{mouse}->{x} -= $border_offset;
    $self->{mouse}->{y} -= $border_offset;

    bmwqemu::diag "mouse_move $self->{mouse}->{x}, $self->{mouse}->{y}";
    $self->{vnc}->mouse_move_to($self->{mouse}->{x}, $self->{mouse}->{y});
    return {absolute => $self->{vnc}->absolute};

}

sub mouse_set {
    my ($self, $args) = @_;

    # TODO: for framebuffers larger than 1024x768, we need to upscale
    $self->{mouse}->{x} = int($args->{x});
    $self->{mouse}->{y} = int($args->{y});

    bmwqemu::diag "mouse_set $self->{mouse}->{x}, $self->{mouse}->{y}";
    $self->{vnc}->mouse_move_to($self->{mouse}->{x}, $self->{mouse}->{y});
    return {};
}

sub mouse_button {
    my ($self, $args) = @_;

    my $button = $args->{button};
    my $bstate = $args->{bstate};

    my $mask = 0;
    if ($button eq 'left') {
        $mask = $bstate;
    }
    elsif ($button eq 'right') {
        $mask = $bstate << 2;
    }
    elsif ($button eq 'middle') {
        $mask = $bstate << 1;
    }
    bmwqemu::diag "pointer_event $mask $self->{mouse}->{x}, $self->{mouse}->{y}";
    $self->{vnc}->send_pointer_event($mask, $self->{mouse}->{x}, $self->{mouse}->{y});
    return {};
}

1;
