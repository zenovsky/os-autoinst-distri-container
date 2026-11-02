#!/usr/bin/env perl
# Конвертирует steps-<suite>.json (StepReport.pm) в формат Allure results.
#
# Использование:
#   steps-to-allure.pl <allure-results-dir> <openqa_job_url> <job_id> <steps.json> [<steps.json> ...]
#
# Один steps-*.json = один Allure test (тест-модуль openQA), каждый step = Allure step,
# действия внутри шага (step_log/run_cmd) = вложенные подшаги, команда+код+вывод = attachment.
# Затем: allure generate <allure-results-dir> -o allure-report --clean
use strict;
use warnings;
use JSON::PP;
use Digest::MD5 qw(md5_hex);
use File::Path qw(make_path);

my ($outdir, $job_url, $job_id, @files) = @ARGV;
die "usage: steps-to-allure.pl <outdir> <openqa_job_url> <job_id> <steps.json>...\n"
  unless defined $outdir && defined $job_url && defined $job_id && @files;
make_path($outdir);

my $json = JSON::PP->new->utf8->canonical->pretty;

sub uuid {
    my $h = md5_hex(join '|', @_, rand(), time);
    return join '-', substr($h, 0, 8), substr($h, 8, 4), substr($h, 12, 4), substr($h, 16, 4), substr($h, 20, 12);
}

sub ms { return int(($_[0] // 0) * 1000) }

sub write_attachment {
    my ($name, $text) = @_;
    my $src = uuid($name) . '-attachment.txt';
    open my $fh, '>:encoding(UTF-8)', "$outdir/$src" or die "write $outdir/$src: $!\n";
    print $fh $text;
    close $fh;
    return {name => $name, source => $src, type => 'text/plain'};
}

# Превращает список actions шага в подшаги. Описание (step_log) + следующий за ним
# блок "$ cmd / exit code: N / вывод" склеиваются в один подшаг с attachment.
sub build_substeps {
    my ($step, $t_start, $t_stop) = @_;
    my @actions = @{$step->{actions} // []};
    my @sub;
    my $pending;    # описание, ожидающее блок команды
    my $flush = sub {
        return unless defined $pending;
        push @sub, {name => $pending, status => 'passed', stage => 'finished', start => $t_start, stop => $t_stop};
        undef $pending;
    };
    for my $a (@actions) {
        if ($a =~ /\A\$ /) {
            my ($rc) = $a =~ /^exit code: (-?\d+)/m;
            my $desc = defined $pending ? $pending : (split /\n/, $a)[0];
            push @sub, {
                name => $desc,
                status => (defined $rc && $rc == 0) ? 'passed' : 'failed',
                stage => 'finished', start => $t_start, stop => $t_stop,
                attachments => [write_attachment('command output', $a)],
            };
            undef $pending;
        }
        else {
            $flush->();
            $pending = $a;
        }
    }
    $flush->();
    return \@sub;
}

for my $file (@files) {
    open my $in, '<:raw', $file or die "open $file: $!\n";
    local $/;
    my $data = $json->decode(<$in>);
    close $in;

    my $suite = $data->{suite} // 'unknown';
    my @steps = @{$data->{steps} // []};

    my ($t0) = sort { $a <=> $b } map { $_->{start} // () } @steps;
    $t0 //= time;
    my $t_end = $t0;
    my @allure_steps;
    my ($first_fail);

    for my $s (@steps) {
        my $start = ms($s->{start});
        my $stop = ms(($s->{start} // 0) + ($s->{duration} // 0));
        $t_end = ($s->{start} // 0) + ($s->{duration} // 0) if (($s->{start} // 0) + ($s->{duration} // 0)) > $t_end;

        my $status = $s->{status} eq 'failed' ? 'failed'
          : $s->{status} eq 'skipped' ? 'skipped'
          : 'passed';
        $first_fail //= $s if $status eq 'failed';

        my $step = {
            name => $s->{name}, status => $status, stage => 'finished',
            start => $start, stop => $stop,
            steps => build_substeps($s, $start, $stop),
        };
        if ($status eq 'failed') {
            my $trace = defined $s->{last_cmd}
              ? "\$ $s->{last_cmd}{cmd}\nexit code: $s->{last_cmd}{rc}\n$s->{last_cmd}{output}"
              : ($s->{error} // '');
            $step->{statusDetails} = {message => $s->{reason} // 'failed', trace => $trace};
        }
        elsif ($status eq 'skipped') {
            $step->{statusDetails} = {message => $s->{reason} // 'skipped'};
        }
        push @allure_steps, $step;
    }

    my $overall = $first_fail ? 'failed' : 'passed';
    my $result = {
        uuid => uuid($suite, $file),
        historyId => md5_hex("$suite"),    # стабильный id, чтобы Allure строил историю прогонов
        testCaseId => md5_hex("$suite"),
        name => $suite,
        fullName => "openqa.$suite",
        status => $overall,
        stage => 'finished',
        start => ms($t0),
        stop => ms($t_end),
        labels => [
            {name => 'framework', value => 'openQA'},
            {name => 'suite', value => $suite},
            {name => 'host', value => "openqa-job-$job_id"},
        ],
        links => [{name => "openQA job $job_id", url => $job_url, type => 'link'}],
        steps => \@allure_steps,
    };
    if ($first_fail) {
        $result->{statusDetails} = {
            message => "$first_fail->{name}: " . ($first_fail->{reason} // 'failed'),
            trace => $first_fail->{last_cmd}
            ? "\$ $first_fail->{last_cmd}{cmd}\nexit code: $first_fail->{last_cmd}{rc}\n$first_fail->{last_cmd}{output}"
            : ($first_fail->{error} // ''),
        };
    }

    my $out = "$outdir/" . $result->{uuid} . '-result.json';
    open my $fh, '>:raw', $out or die "write $out: $!\n";
    print $fh $json->encode($result);
    close $fh;
    print "allure: $file -> $out ($overall, " . scalar(@steps) . " steps)\n";
}