#!/usr/bin/env perl
# Формирует метрики для InfluxDB (line protocol) из данных job'а openQA и steps-<suite>.json.
#
# Использование:
#   steps-to-influx.pl <out.lp> <job_id> <job-info.json> [<steps.json> ...]
#
#   job-info.json - ответ `openqa-cli api jobs/<id>` (нужны .job.test/.result/.t_started/.t_finished)
#   Строки ДОБАВЛЯЮТСЯ в <out.lp>. Метаданные CI берутся из переменных окружения GitLab:
#   CI_COMMIT_REF_NAME, CI_COMMIT_SHORT_SHA, CI_PIPELINE_ID, CI_PIPELINE_URL, CI_JOB_URL, OPENQA_URL.
#
# Measurements:
#   openqa_job  tags: scenario,result,branch          fields: duration_s,job_id,pipeline_id,commit,openqa_url,gitlab_url
#   openqa_step tags: suite,step,status,branch,qase_id fields: duration_s,failed,job_id,pipeline_id
use strict;
use warnings;
use JSON::PP;
use Time::Local qw(timegm);

my ($out, $job_id, $job_file, @steps_files) = @ARGV;
die "usage: steps-to-influx.pl <out.lp> <job_id> <job-info.json> [<steps.json>...]\n"
  unless defined $out && defined $job_id && defined $job_file;

sub slurp {
    my ($f) = @_;
    open my $fh, '<:raw', $f or die "open $f: $!\n";
    local $/;
    return scalar <$fh>;
}

# Экранирование по правилам line protocol.
sub tag { my $v = shift // ''; $v = 'none' if $v eq ''; $v =~ s/([,= \\])/\\$1/g; $v =~ s/[\r\n]+/ /g; return $v }
sub str { my $v = shift // ''; $v =~ s/([\\"])/\\$1/g; $v =~ s/[\r\n]+/ /g; return "\"$v\"" }
sub num { my $v = shift; return (defined $v && $v =~ /^-?\d+(\.\d+)?$/) ? $v + 0 : 0 }

# "2026-11-03T12:34:56" (UTC, без часового пояса) -> epoch
sub parse_ts {
    my ($s) = @_;
    return unless defined $s && $s =~ /^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d):(\d\d)/;
    return timegm($6, $5, $4, $3, $2 - 1, $1);
}

my $branch = $ENV{CI_COMMIT_REF_NAME} // 'local';
my $commit = $ENV{CI_COMMIT_SHORT_SHA} // '';
my $pipeline = $ENV{CI_PIPELINE_ID} // 0;
my $gitlab_url = $ENV{CI_JOB_URL} // $ENV{CI_PIPELINE_URL} // '';
my $openqa_url = ($ENV{OPENQA_URL} // '') . "/tests/$job_id";

my $job = decode_json(slurp($job_file))->{job} // {};
my $t_start = parse_ts($job->{t_started});
my $t_end = parse_ts($job->{t_finished}) // time;
my $duration = (defined $t_start && $t_end >= $t_start) ? $t_end - $t_start : 0;

my @lines;
push @lines, sprintf 'openqa_job,scenario=%s,result=%s,branch=%s duration_s=%s,job_id=%di,pipeline_id=%di,commit=%s,openqa_url=%s,gitlab_url=%s %d',
  tag($job->{test}), tag($job->{result} // 'unknown'), tag($branch),
  $duration, $job_id, num($pipeline), str($commit), str($openqa_url), str($gitlab_url), $t_end * 1_000_000_000;

for my $file (@steps_files) {
    my $data = decode_json(slurp($file));
    my $suite = $data->{suite} // 'unknown';
    my $qase = $data->{qase_id};
    my $n = 0;
    for my $s (@{$data->{steps} // []}) {
        # Уникальность точки: серия = теги, время = начало шага. Добавляем порядковый номер
        # в наносекунды, чтобы два шага, начавшиеся в одну секунду, не затёрли друг друга.
        my $ts = int(($s->{start} // $t_end) * 1_000_000_000) + $n++;
        my $status = $s->{status} // 'unknown';
        push @lines, sprintf 'openqa_step,suite=%s,step=%s,status=%s,branch=%s,qase_id=%s duration_s=%s,failed=%di,job_id=%di,pipeline_id=%di %d',
          tag($suite), tag($s->{name}), tag($status), tag($branch), tag($qase),
          num($s->{duration}), $status eq 'failed' ? 1 : 0, $job_id, num($pipeline), $ts;
    }
}

open my $fh, '>>:encoding(UTF-8)', $out or die "append $out: $!\n";
print $fh "$_\n" for @lines;
close $fh;
print "influx: job $job_id -> " . scalar(@lines) . " point(s) in $out\n";
