package StepReport;

# Записывает шаги теста (имя, статус, длительность, ошибка) и в конце сохраняет
# их как артефакты job'а: steps-<suite>.json (источник правды) и junit-<suite>.xml.
#
# Использование в тесте:
#   use StepReport;
#   step '05. sshd listens on 22' => sub { assert_script_run "ss -lntp | grep ':22'" };
#   sub post_fail_hook { write_step_report('ssh_client') }
#   sub post_run_hook  { write_step_report('ssh_client') }

use strict;
use warnings;
use Exporter 'import';
use Time::HiRes 'time';
use Mojo::JSON 'encode_json';
use Mojo::File 'path';
use Mojo::Util qw(xml_escape encode);
use testapi;

our @EXPORT = qw(step write_step_report);

my @STEPS;    # шаги текущего job'а (живут в памяти isotovideo)

sub step {
    my ($name, $code) = @_;
    my $start = time;
    diag("[STEP] START: $name");
    my $ok  = eval { $code->(); 1 };
    my $err = $@ || 'unknown error';
    my $dur = time - $start;

    my $rec = {name => $name, status => $ok ? 'passed' : 'failed', start => $start, duration => $dur};
    $rec->{error} = "$err" unless $ok;
    push @STEPS, $rec;

    diag(sprintf '[STEP] %s: %s (%.1fs)', $ok ? 'PASS' : 'FAIL', $name, $dur);
    return 1 if $ok;
    record_info("FAIL: $name", "$err", result => 'fail');
    die $err;
}

# Убираем управляющие символы (ANSI и т.п.): они делают XML невалидным.
sub _clean {
    my ($s) = @_;
    $s //= '';
    $s =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g;
    return $s;
}

sub write_step_report {
    my ($suite) = @_;
    $suite //= get_var('TEST', 'openqa');
    my $failures = grep { $_->{status} eq 'failed' } @STEPS;
    my $total = 0;
    $total += $_->{duration} for @STEPS;

    my $xml = sprintf qq{<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n}
      . qq{<testsuite name="%s" tests="%d" failures="%d" time="%.3f">\n},
      xml_escape($suite), scalar @STEPS, $failures, $total;

    for my $s (@STEPS) {
        $xml .= sprintf '  <testcase classname="%s" name="%s" time="%.3f"',
          xml_escape($suite), xml_escape(_clean($s->{name})), $s->{duration};
        if ($s->{status} eq 'failed') {
            my $err   = _clean($s->{error});
            my ($msg) = split /\n/, $err;
            $xml .= sprintf ">\n    <failure message=\"%s\">%s</failure>\n  </testcase>\n",
              xml_escape($msg // ''), xml_escape($err);
        }
        else {
            $xml .= " />\n";
        }
    }
    $xml .= "</testsuite>\n</testsuites>\n";

    my $dir = path('ulogs')->make_path;
    $dir->child("junit-$suite.xml")->spew(encode('UTF-8', $xml));
    $dir->child("steps-$suite.json")->spew(encode_json({suite => $suite, steps => \@STEPS}));
    diag("[STEP] report written: ulogs/junit-$suite.xml, ulogs/steps-$suite.json");
    return;
}

1;