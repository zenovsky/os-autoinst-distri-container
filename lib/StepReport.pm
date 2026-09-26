package StepReport;

# Записывает шаги теста и в конце сохраняет их как артефакты job'а:
#   steps-<suite>.json  - источник правды (шаги, действия, ошибки, фрагмент autoinst-log.txt)
#   junit-<suite>.xml   - JUnit для CI (testcase = шаг, system-out = журнал действий)
#
# Использование в тесте:
#   use StepReport;
#   step 'P1. Network setup' => sub {
#       step_log "Activating connection ens4-static";          # что делаем (английское описание)
#       assert_script_run "nmcli con up ens4-static";
#   }, fail => 'Could not bring the static connection up';    # необязательно: своя причина ошибки
#   sub post_fail_hook { write_step_report('ssh_client', failed => 1) }
#   sub post_run_hook  { write_step_report('ssh_client') }
#
# Причина ошибки:
#   - если задан fail => '...', берётся он;
#   - иначе "Failed while: <последнее step_log шага>";
#   - подробный текст ошибки идёт отдельно (Details).

use strict;
use warnings;
no warnings 'once';
use Exporter 'import';
use Time::HiRes 'time';
use Mojo::JSON 'encode_json';
use Mojo::File 'path';
use Mojo::Util qw(xml_escape encode decode);
use testapi;

our @EXPORT = qw(step step_log run_cmd probe_cmd write_step_report add_step_secret);

my @STEPS;                        # шаги текущего job'а (живут в памяти isotovideo)
my $CURRENT;                      # запись выполняющегося шага
my @SECRETS;                      # значения, которые нельзя выводить в отчёт
my $LOG             = 'autoinst-log.txt';
my $MAX_LOG_LINES   = 80;
my $MAX_TEXT_CHARS  = 20000;
my $MAX_CMD_OUTPUT  = 4000;
my $CMD_TIMEOUT     = 90;         # значение по умолчанию для run_cmd, как у assert_script_run

sub add_step_secret { push @SECRETS, grep { defined && length } @_; return }

# Маскируем пароли: значения переменных *PASSWORD*/*SECRET*/*TOKEN*, $testapi::password и всё из add_step_secret.
sub _mask {
    my ($s) = @_;
    return $s unless defined $s && length $s;
    my @secrets = @SECRETS;
    push @secrets, $testapi::password if defined $testapi::password;
    for my $k (keys %bmwqemu::vars) {
        push @secrets, $bmwqemu::vars{$k} if $k =~ /PASSWORD|SECRET|TOKEN/ && defined $bmwqemu::vars{$k};
    }
    for my $sec (sort { length $b <=> length $a } grep { defined && length > 3 } @secrets) {
        $s =~ s/\Q$sec\E/****/g;
    }
    return $s;
}

# Убираем управляющие символы (ANSI и т.п.): они делают XML невалидным. Ограничиваем размер.
sub _clean {
    my ($s) = @_;
    return _clean_len($s, $MAX_TEXT_CHARS);
}

sub _clean_len {
    my ($s, $max) = @_;
    $s //= '';
    $s =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g;
    $s = "... (truncated)\n" . substr($s, -$max) if length $s > $max;
    return $s;
}

# Всё, что isotovideo записал в autoinst-log.txt начиная с байтовой позиции $pos (последние N строк).
sub _log_since {
    my ($pos) = @_;
    return '' unless -f $LOG;
    open my $fh, '<:raw', $LOG or return '';
    seek $fh, $pos, 0;
    local $/;
    my $txt = <$fh> // '';
    close $fh;
    my $dec = decode('UTF-8', $txt);
    $txt = $dec if defined $dec;
    my @lines = split /\n/, $txt;
    splice @lines, 0, @lines - $MAX_LOG_LINES if @lines > $MAX_LOG_LINES;
    return join "\n", @lines;
}

# Описание действия внутри шага: идёт в autoinst-log.txt и в журнал шага.
sub step_log {
    my ($msg) = @_;
    $msg = _mask($msg);
    diag("[STEP] $msg");
    push @{$CURRENT->{actions}}, $msg if $CURRENT;
    return;
}

# Общая часть run_cmd/probe_cmd: выполняет команду, явно перехватывает код возврата и
# консольный вывод (через временный файл), вместо того чтобы полагаться на debug-трассировку
# isotovideo в autoinst-log.txt. Возвращает (rc, вывод с маскированными секретами).
sub _exec_capture {
    my ($cmd, %opt) = @_;
    my $timeout = $opt{timeout} // $CMD_TIMEOUT;
    my $marker  = 'STEPCMD_' . int(rand(1_000_000)) . '_' . time;
    my $tmp     = "/tmp/$marker.log";
    # Оборачиваем исходную команду как есть: она уже полноценная shell-строка (с пайпами и т.п.).
    my $wrapped = "{ $cmd ; } > $tmp 2>&1; echo ${marker}_RC=\$? >> $tmp";
    testapi::script_run($wrapped, timeout => $timeout);

    my $raw = testapi::script_output("cat $tmp", quiet => 1, proceed_on_failure => 1) // '';
    testapi::script_run("rm -f $tmp", quiet => 1, timeout => 10);

    my ($rc)     = $raw =~ /\Q$marker\E_RC=(-?\d+)/;
    (my $out = $raw) =~ s/\Q$marker\E_RC=-?\d+\s*\z//;
    $out =~ s/\s+\z//;
    $rc = defined $rc ? $rc : -1;    # -1: не смогли прочитать код возврата (например, ушла консоль)
    return ($rc, _mask($out));
}

# Выполняет shell-команду и требует код возврата 0 (как assert_script_run). При ошибке
# в отчёт попадает "$ команда / exit code / вывод", без сотен строк debug-лога.
#
#   run_cmd "Checking sshd port" => "sshd -T | grep 'port 22'";
sub run_cmd {
    my ($desc, $cmd, %opt) = @_;
    ($desc, $cmd) = ($cmd, $cmd) unless defined $cmd;    # run_cmd($cmd) без отдельного описания
    step_log($desc);
    my ($rc, $out) = _exec_capture($cmd, %opt);
    if ($CURRENT) {
        $CURRENT->{last_cmd} = {cmd => $cmd, rc => $rc, output => $out};
    }
    die "Command exited with code $rc: $cmd\n" if $rc != 0;
    return $out;
}

# Как run_cmd, но не проверяет код возврата сама - для команд с несколькими законными
# исходами (dnf check-update: 0/100/иное), где решение принимает сам тест. Код и вывод
# всегда попадают в журнал шага, а не только при ошибке - чтобы было видно, ПОЧЕМУ тест
# пошёл по той или иной ветке.
#
#   my ($rc, $out) = probe_cmd "Checking for an update" => "dnf check-update openssh", timeout => 300;
#   if ($rc == 100) { ... an update is available ... }
sub probe_cmd {
    my ($desc, $cmd, %opt) = @_;
    step_log($desc);
    my ($rc, $out) = _exec_capture($cmd, %opt);
    step_log("\$ $cmd\nexit code: $rc" . (length($out) ? "\n$out" : "\n(no output)"));
    return ($rc, $out);
}

sub step {
    my ($name, $code, %opt) = @_;
    my ($file, $line) = (caller)[1, 2];
    $file =~ s{^.*/(?=(?:tests|lib)/)}{};
    my $where = "$file:$line";
    my $start = time;
    my $rec     = {name => $name, status => 'passed', start => $start, location => $where, actions => []};
    diag("[STEP] START: $name");

    my $prev = $CURRENT;
    $CURRENT = $rec;
    my $ok  = eval { $code->(); 1 };
    my $err = $@ || 'unknown error';
    $CURRENT = $prev;
    $rec->{duration} = time - $start;

    unless ($ok) {
        my $last = $rec->{actions}[-1];
        $rec->{status}      = 'failed';
        $rec->{reason}      = _mask($opt{fail} // (defined $last ? "Failed while: $last" : "Step '$name' failed"));
        $rec->{error} = _mask("$err");
        # Никакого сырого autoinst-log.txt здесь: если команда падала через run_cmd, у неё уже
        # есть чистые cmd/rc/output (last_cmd). Остальные шаги (assert_screen и т.п.) и так дают
        # понятную одну строку ошибки от testapi, без debug-трассировки isotovideo.
    }
    push @STEPS, $rec;

    diag(sprintf '[STEP] %s: %s (%.1fs)', $ok ? 'PASS' : 'FAIL', $name, $rec->{duration});
    return 1 if $ok;
    diag("[STEP] REASON: $rec->{reason}");
    record_info("FAIL: $name", "$where\n$rec->{reason}\n\n$rec->{error}", result => 'fail');
    die $err;
}

sub write_step_report {
    my ($suite, %opt) = @_;
    $suite //= get_var('TEST', 'openqa');

    # Тест упал вне шага (например, в barrier_wait): без этого отчёт остался бы зелёным.
    if ($opt{failed} && !grep { $_->{status} eq 'failed' } @STEPS) {
        my $after = @STEPS ? "after step '$STEPS[-1]{name}'" : 'before the first step';
        push @STEPS, {
            name     => 'Failure outside of a step', status => 'failed', start => time, duration => 0,
            location => 'n/a', actions => [],
            reason   => "Test stopped unexpectedly outside of any step $after (for example in barrier_wait)",
            error    => "Last lines of autoinst-log.txt:\n" . _mask(_log_since(0)),
        };
    }

    my $failures = grep { $_->{status} eq 'failed' } @STEPS;
    my $total = 0;
    $total += $_->{duration} for @STEPS;

    my $xml = sprintf qq{<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n}
      . qq{<testsuite name="%s" tests="%d" failures="%d" time="%.3f">\n},
      xml_escape($suite), scalar @STEPS, $failures, $total;

    for my $s (@STEPS) {
        my $failed = $s->{status} eq 'failed';
        my @out    = @{$s->{actions} // []};
        push @out, "ERROR: $s->{reason}" if $failed;

        my $details = "at $s->{location}\nDetails: $s->{error}";
        if ($failed && $s->{last_cmd}) {
            my $c        = $s->{last_cmd};
            my $cmd_out  = length($c->{output}) ? _clean_len($c->{output}, $MAX_CMD_OUTPUT) : '(no output)';
            my $cmd_text = "\$ $c->{cmd}\nexit code: $c->{rc}\n$cmd_out";
            push @out, '', $cmd_text;
            $details = $cmd_text;    # сама команда/код/вывод важнее внутреннего Perl-текста ошибки
        }
        my $out = _clean(join "\n", @out);

        my $body = '';
        if ($failed) {
            my ($msg) = split /\n/, $s->{reason};
            $body .= sprintf qq{    <failure message="%s" type="StepFailure">%s</failure>\n},
              xml_escape(_clean($msg)), xml_escape(_clean($details));
        }
        $body .= sprintf "    <system-out>%s</system-out>\n", xml_escape($out) if length $out;

        my $attrs = sprintf 'classname="%s" name="%s" file="%s" time="%.3f"',
          xml_escape($suite), xml_escape(_clean($s->{name})), xml_escape($s->{location}), $s->{duration};
        $xml .= length $body ? "  <testcase $attrs>\n$body  </testcase>\n" : "  <testcase $attrs />\n";
    }
    $xml .= "</testsuite>\n</testsuites>\n";

    my $dir = path('ulogs')->make_path;
    $dir->child("junit-$suite.xml")->spew(encode('UTF-8', $xml));
    $dir->child("steps-$suite.json")->spew(encode_json({suite => $suite, steps => \@STEPS}));
    diag("[STEP] report written: ulogs/junit-$suite.xml, ulogs/steps-$suite.json");
    return;
}

1;

# package StepReport;

# # Записывает шаги теста и в конце сохраняет их как артефакты job'а:
# #   steps-<suite>.json  - источник правды (шаги, действия, ошибки, фрагмент autoinst-log.txt)
# #   junit-<suite>.xml   - JUnit для CI (testcase = шаг, system-out = журнал действий)
# #
# # Использование в тесте:
# #   use StepReport;
# #   step 'P1. Network setup' => sub {
# #       step_log "Activating connection ens4-static";          # что делаем (английское описание)
# #       assert_script_run "nmcli con up ens4-static";
# #   }, fail => 'Could not bring the static connection up';    # необязательно: своя причина ошибки
# #   sub post_fail_hook { write_step_report('ssh_client', failed => 1) }
# #   sub post_run_hook  { write_step_report('ssh_client') }
# #
# # Причина ошибки:
# #   - если задан fail => '...', берётся он;
# #   - иначе "Failed while: <последнее step_log шага>";
# #   - подробный текст ошибки идёт отдельно (Details).

# use strict;
# use warnings;
# no warnings 'once';
# use Exporter 'import';
# use Time::HiRes 'time';
# use Mojo::JSON 'encode_json';
# use Mojo::File 'path';
# use Mojo::Util qw(xml_escape encode decode);
# use testapi;

# our @EXPORT = qw(step step_log run_cmd write_step_report add_step_secret);

# my @STEPS;                        # шаги текущего job'а (живут в памяти isotovideo)
# my $CURRENT;                      # запись выполняющегося шага
# my @SECRETS;                      # значения, которые нельзя выводить в отчёт
# my $LOG             = 'autoinst-log.txt';
# my $MAX_LOG_LINES   = 80;
# my $MAX_TEXT_CHARS  = 20000;
# my $MAX_CMD_OUTPUT  = 4000;
# my $CMD_TIMEOUT     = 90;         # значение по умолчанию для run_cmd, как у assert_script_run

# sub add_step_secret { push @SECRETS, grep { defined && length } @_; return }

# # Маскируем пароли: значения переменных *PASSWORD*/*SECRET*/*TOKEN*, $testapi::password и всё из add_step_secret.
# sub _mask {
#     my ($s) = @_;
#     return $s unless defined $s && length $s;
#     my @secrets = @SECRETS;
#     push @secrets, $testapi::password if defined $testapi::password;
#     for my $k (keys %bmwqemu::vars) {
#         push @secrets, $bmwqemu::vars{$k} if $k =~ /PASSWORD|SECRET|TOKEN/ && defined $bmwqemu::vars{$k};
#     }
#     for my $sec (sort { length $b <=> length $a } grep { defined && length > 3 } @secrets) {
#         $s =~ s/\Q$sec\E/****/g;
#     }
#     return $s;
# }

# # Убираем управляющие символы (ANSI и т.п.): они делают XML невалидным. Ограничиваем размер.
# sub _clean {
#     my ($s) = @_;
#     return _clean_len($s, $MAX_TEXT_CHARS);
# }

# sub _clean_len {
#     my ($s, $max) = @_;
#     $s //= '';
#     $s =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g;
#     $s = "... (truncated)\n" . substr($s, -$max) if length $s > $max;
#     return $s;
# }

# # Всё, что isotovideo записал в autoinst-log.txt начиная с байтовой позиции $pos (последние N строк).
# sub _log_since {
#     my ($pos) = @_;
#     return '' unless -f $LOG;
#     open my $fh, '<:raw', $LOG or return '';
#     seek $fh, $pos, 0;
#     local $/;
#     my $txt = <$fh> // '';
#     close $fh;
#     my $dec = decode('UTF-8', $txt);
#     $txt = $dec if defined $dec;
#     my @lines = split /\n/, $txt;
#     splice @lines, 0, @lines - $MAX_LOG_LINES if @lines > $MAX_LOG_LINES;
#     return join "\n", @lines;
# }

# # Описание действия внутри шага: идёт в autoinst-log.txt и в журнал шага.
# sub step_log {
#     my ($msg) = @_;
#     $msg = _mask($msg);
#     diag("[STEP] $msg");
#     push @{$CURRENT->{actions}}, $msg if $CURRENT;
#     return;
# }

# # Выполняет shell-команду и явно перехватывает код возврата и консольный вывод, вместо того
# # чтобы полагаться на debug-трассировку isotovideo в autoinst-log.txt.
# #
# #   run_cmd "Checking sshd port" => "sshd -T | grep 'port 22'";
# #   my $out = run_cmd "List keys" => "ls -l ~/.ssh/", quiet => 1;   # не логировать вывод при успехе
# #
# # По умолчанию успехом считается код возврата 0 (как assert_script_run). При ошибке
# # в отчёт попадает именно "$ команда / exit code / вывод", без сотен строк debug-лога.
# sub run_cmd {
#     my ($desc, $cmd, %opt) = @_;
#     ($desc, $cmd) = ($cmd, $cmd) unless defined $cmd;    # run_cmd($cmd) без отдельного описания
#     step_log($desc);

#     my $timeout = $opt{timeout} // $CMD_TIMEOUT;
#     my $marker  = 'STEPCMD_' . int(rand(1_000_000)) . '_' . time;
#     my $tmp     = "/tmp/$marker.log";
#     # Оборачиваем исходную команду как есть: она уже полноценная shell-строка (с пайпами и т.п.).
#     my $wrapped = "{ $cmd ; } > $tmp 2>&1; echo ${marker}_RC=\$? >> $tmp";
#     testapi::script_run($wrapped, timeout => $timeout);

#     my $raw = testapi::script_output("cat $tmp", quiet => 1, proceed_on_failure => 1) // '';
#     testapi::script_run("rm -f $tmp", quiet => 1, timeout => 10);

#     my ($rc)     = $raw =~ /\Q$marker\E_RC=(-?\d+)/;
#     (my $out = $raw) =~ s/\Q$marker\E_RC=-?\d+\s*\z//;
#     $out =~ s/\s+\z//;
#     $rc = defined $rc ? $rc : -1;    # -1: не смогли прочитать код возврата (например, ушла консоль)

#     if ($CURRENT) {
#         $CURRENT->{last_cmd} = {cmd => $cmd, rc => $rc, output => _mask($out)};
#     }
#     die "Command exited with code $rc: $cmd\n" if $rc != 0;
#     return _mask($out);
# }

# sub step {
#     my ($name, $code, %opt) = @_;
#     my ($file, $line) = (caller)[1, 2];
#     $file =~ s{^.*/(?=(?:tests|lib)/)}{};
#     my $where = "$file:$line";
#     my $start = time;
#     my $rec     = {name => $name, status => 'passed', start => $start, location => $where, actions => []};
#     diag("[STEP] START: $name");

#     my $prev = $CURRENT;
#     $CURRENT = $rec;
#     my $ok  = eval { $code->(); 1 };
#     my $err = $@ || 'unknown error';
#     $CURRENT = $prev;
#     $rec->{duration} = time - $start;

#     unless ($ok) {
#         my $last = $rec->{actions}[-1];
#         $rec->{status}      = 'failed';
#         $rec->{reason}      = _mask($opt{fail} // (defined $last ? "Failed while: $last" : "Step '$name' failed"));
#         $rec->{error} = _mask("$err");
#         # Никакого сырого autoinst-log.txt здесь: если команда падала через run_cmd, у неё уже
#         # есть чистые cmd/rc/output (last_cmd). Остальные шаги (assert_screen и т.п.) и так дают
#         # понятную одну строку ошибки от testapi, без debug-трассировки isotovideo.
#     }
#     push @STEPS, $rec;

#     diag(sprintf '[STEP] %s: %s (%.1fs)', $ok ? 'PASS' : 'FAIL', $name, $rec->{duration});
#     return 1 if $ok;
#     diag("[STEP] REASON: $rec->{reason}");
#     record_info("FAIL: $name", "$where\n$rec->{reason}\n\n$rec->{error}", result => 'fail');
#     die $err;
# }

# sub write_step_report {
#     my ($suite, %opt) = @_;
#     $suite //= get_var('TEST', 'openqa');

#     # Тест упал вне шага (например, в barrier_wait): без этого отчёт остался бы зелёным.
#     if ($opt{failed} && !grep { $_->{status} eq 'failed' } @STEPS) {
#         my $after = @STEPS ? "after step '$STEPS[-1]{name}'" : 'before the first step';
#         push @STEPS, {
#             name     => 'Failure outside of a step', status => 'failed', start => time, duration => 0,
#             location => 'n/a', actions => [],
#             reason   => "Test stopped unexpectedly outside of any step $after (for example in barrier_wait)",
#             error    => "Last lines of autoinst-log.txt:\n" . _mask(_log_since(0)),
#         };
#     }

#     my $failures = grep { $_->{status} eq 'failed' } @STEPS;
#     my $total = 0;
#     $total += $_->{duration} for @STEPS;

#     my $xml = sprintf qq{<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n}
#       . qq{<testsuite name="%s" tests="%d" failures="%d" time="%.3f">\n},
#       xml_escape($suite), scalar @STEPS, $failures, $total;

#     for my $s (@STEPS) {
#         my $failed = $s->{status} eq 'failed';
#         my @out    = @{$s->{actions} // []};
#         push @out, "ERROR: $s->{reason}" if $failed;

#         my $details = "at $s->{location}\nDetails: $s->{error}";
#         if ($failed && $s->{last_cmd}) {
#             my $c        = $s->{last_cmd};
#             my $cmd_out  = length($c->{output}) ? _clean_len($c->{output}, $MAX_CMD_OUTPUT) : '(no output)';
#             my $cmd_text = "\$ $c->{cmd}\nexit code: $c->{rc}\n$cmd_out";
#             push @out, '', $cmd_text;
#             $details = $cmd_text;    # сама команда/код/вывод важнее внутреннего Perl-текста ошибки
#         }
#         my $out = _clean(join "\n", @out);

#         my $body = '';
#         if ($failed) {
#             my ($msg) = split /\n/, $s->{reason};
#             $body .= sprintf qq{    <failure message="%s" type="StepFailure">%s</failure>\n},
#               xml_escape(_clean($msg)), xml_escape(_clean($details));
#         }
#         $body .= sprintf "    <system-out>%s</system-out>\n", xml_escape($out) if length $out;

#         my $attrs = sprintf 'classname="%s" name="%s" file="%s" time="%.3f"',
#           xml_escape($suite), xml_escape(_clean($s->{name})), xml_escape($s->{location}), $s->{duration};
#         $xml .= length $body ? "  <testcase $attrs>\n$body  </testcase>\n" : "  <testcase $attrs />\n";
#     }
#     $xml .= "</testsuite>\n</testsuites>\n";

#     my $dir = path('ulogs')->make_path;
#     $dir->child("junit-$suite.xml")->spew(encode('UTF-8', $xml));
#     $dir->child("steps-$suite.json")->spew(encode_json({suite => $suite, steps => \@STEPS}));
#     diag("[STEP] report written: ulogs/junit-$suite.xml, ulogs/steps-$suite.json");
#     return;
# }

# 1;

# package StepReport;

# # Записывает шаги теста и в конце сохраняет их как артефакты job'а:
# #   steps-<suite>.json  - источник правды (шаги, действия, ошибки, фрагмент autoinst-log.txt)
# #   junit-<suite>.xml   - JUnit для CI (testcase = шаг, system-out = журнал действий)
# #
# # Использование в тесте:
# #   use StepReport;
# #   step 'P1. Network setup' => sub {
# #       step_log "Activating connection ens4-static";          # что делаем (английское описание)
# #       assert_script_run "nmcli con up ens4-static";
# #   }, fail => 'Could not bring the static connection up';    # необязательно: своя причина ошибки
# #   sub post_fail_hook { write_step_report('ssh_client', failed => 1) }
# #   sub post_run_hook  { write_step_report('ssh_client') }
# #
# # Причина ошибки:
# #   - если задан fail => '...', берётся он;
# #   - иначе "Failed while: <последнее step_log шага>";
# #   - подробный текст ошибки идёт отдельно (Details).

# use strict;
# use warnings;
# no warnings 'once';
# use Exporter 'import';
# use Time::HiRes 'time';
# use Mojo::JSON 'encode_json';
# use Mojo::File 'path';
# use Mojo::Util qw(xml_escape encode decode);
# use testapi;

# our @EXPORT = qw(step step_log run_cmd write_step_report add_step_secret);

# my @STEPS;                        # шаги текущего job'а (живут в памяти isotovideo)
# my $CURRENT;                      # запись выполняющегося шага
# my @SECRETS;                      # значения, которые нельзя выводить в отчёт
# my $LOG             = 'autoinst-log.txt';
# my $MAX_LOG_LINES   = 80;
# my $MAX_TEXT_CHARS  = 20000;
# my $MAX_CMD_OUTPUT  = 4000;
# my $CMD_TIMEOUT     = 90;         # значение по умолчанию для run_cmd, как у assert_script_run

# sub add_step_secret { push @SECRETS, grep { defined && length } @_; return }

# # Маскируем пароли: значения переменных *PASSWORD*/*SECRET*/*TOKEN*, $testapi::password и всё из add_step_secret.
# sub _mask {
#     my ($s) = @_;
#     return $s unless defined $s && length $s;
#     my @secrets = @SECRETS;
#     push @secrets, $testapi::password if defined $testapi::password;
#     for my $k (keys %bmwqemu::vars) {
#         push @secrets, $bmwqemu::vars{$k} if $k =~ /PASSWORD|SECRET|TOKEN/ && defined $bmwqemu::vars{$k};
#     }
#     for my $sec (sort { length $b <=> length $a } grep { defined && length > 3 } @secrets) {
#         $s =~ s/\Q$sec\E/****/g;
#     }
#     return $s;
# }

# # Убираем управляющие символы (ANSI и т.п.): они делают XML невалидным. Ограничиваем размер.
# sub _clean {
#     my ($s) = @_;
#     return _clean_len($s, $MAX_TEXT_CHARS);
# }

# sub _clean_len {
#     my ($s, $max) = @_;
#     $s //= '';
#     $s =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g;
#     $s = "... (truncated)\n" . substr($s, -$max) if length $s > $max;
#     return $s;
# }

# # Всё, что isotovideo записал в autoinst-log.txt начиная с байтовой позиции $pos (последние N строк).
# sub _log_since {
#     my ($pos) = @_;
#     return '' unless -f $LOG;
#     open my $fh, '<:raw', $LOG or return '';
#     seek $fh, $pos, 0;
#     local $/;
#     my $txt = <$fh> // '';
#     close $fh;
#     my $dec = decode('UTF-8', $txt);
#     $txt = $dec if defined $dec;
#     my @lines = split /\n/, $txt;
#     splice @lines, 0, @lines - $MAX_LOG_LINES if @lines > $MAX_LOG_LINES;
#     return join "\n", @lines;
# }

# # Описание действия внутри шага: идёт в autoinst-log.txt и в журнал шага.
# sub step_log {
#     my ($msg) = @_;
#     $msg = _mask($msg);
#     diag("[STEP] $msg");
#     push @{$CURRENT->{actions}}, $msg if $CURRENT;
#     return;
# }

# # Выполняет shell-команду и явно перехватывает код возврата и консольный вывод, вместо того
# # чтобы полагаться на debug-трассировку isotovideo в autoinst-log.txt.
# #
# #   run_cmd "Checking sshd port" => "sshd -T | grep 'port 22'";
# #   my $out = run_cmd "List keys" => "ls -l ~/.ssh/", quiet => 1;   # не логировать вывод при успехе
# #
# # По умолчанию успехом считается код возврата 0 (как assert_script_run). При ошибке
# # в отчёт попадает именно "$ команда / exit code / вывод", без сотен строк debug-лога.
# sub run_cmd {
#     my ($desc, $cmd, %opt) = @_;
#     ($desc, $cmd) = ($cmd, $cmd) unless defined $cmd;    # run_cmd($cmd) без отдельного описания
#     step_log($desc);

#     my $timeout = $opt{timeout} // $CMD_TIMEOUT;
#     my $marker  = 'STEPCMD_' . int(rand(1_000_000)) . '_' . time;
#     my $tmp     = "/tmp/$marker.log";
#     # Оборачиваем исходную команду как есть: она уже полноценная shell-строка (с пайпами и т.п.).
#     my $wrapped = "{ $cmd ; } > $tmp 2>&1; echo ${marker}_RC=\$? >> $tmp";
#     testapi::script_run($wrapped, timeout => $timeout);

#     my $raw = testapi::script_output("cat $tmp", quiet => 1, proceed_on_failure => 1) // '';
#     testapi::script_run("rm -f $tmp", quiet => 1, timeout => 10);

#     my ($rc)     = $raw =~ /\Q$marker\E_RC=(-?\d+)/;
#     (my $out = $raw) =~ s/\Q$marker\E_RC=-?\d+\s*\z//;
#     $out =~ s/\s+\z//;
#     $rc = defined $rc ? $rc : -1;    # -1: не смогли прочитать код возврата (например, ушла консоль)

#     if ($CURRENT) {
#         $CURRENT->{last_cmd} = {cmd => $cmd, rc => $rc, output => _mask($out)};
#     }
#     die "Command exited with code $rc: $cmd\n" if $rc != 0;
#     return _mask($out);
# }

# sub step {
#     my ($name, $code, %opt) = @_;
#     my ($file, $line) = (caller)[1, 2];
#     $file =~ s{^.*/(?=(?:tests|lib)/)}{};
#     my $where   = "$file:$line";
#     my $log_pos = (-s $LOG) || 0;
#     my $start   = time;
#     my $rec     = {name => $name, status => 'passed', start => $start, location => $where, actions => []};
#     diag("[STEP] START: $name");

#     my $prev = $CURRENT;
#     $CURRENT = $rec;
#     my $ok  = eval { $code->(); 1 };
#     my $err = $@ || 'unknown error';
#     $CURRENT = $prev;
#     $rec->{duration} = time - $start;

#     unless ($ok) {
#         my $last = $rec->{actions}[-1];
#         $rec->{status}      = 'failed';
#         $rec->{reason}      = _mask($opt{fail} // (defined $last ? "Failed while: $last" : "Step '$name' failed"));
#         $rec->{error}       = _mask("$err");
#         # last_cmd уже выставлен run_cmd (если команда упала через него, дальше используем его вместо лога).
#         $rec->{log_excerpt} = _mask(_log_since($log_pos)) unless $rec->{last_cmd};
#     }
#     push @STEPS, $rec;

#     diag(sprintf '[STEP] %s: %s (%.1fs)', $ok ? 'PASS' : 'FAIL', $name, $rec->{duration});
#     return 1 if $ok;
#     diag("[STEP] REASON: $rec->{reason}");
#     record_info("FAIL: $name", "$where\n$rec->{reason}\n\n$rec->{error}", result => 'fail');
#     die $err;
# }

# sub write_step_report {
#     my ($suite, %opt) = @_;
#     $suite //= get_var('TEST', 'openqa');

#     # Тест упал вне шага (например, в barrier_wait): без этого отчёт остался бы зелёным.
#     if ($opt{failed} && !grep { $_->{status} eq 'failed' } @STEPS) {
#         my $after = @STEPS ? "after step '$STEPS[-1]{name}'" : 'before the first step';
#         push @STEPS, {
#             name     => 'Failure outside of a step', status => 'failed', start => time, duration => 0,
#             location => 'n/a', actions => [],
#             reason   => "Test stopped unexpectedly outside of any step $after (for example in barrier_wait)",
#             error    => "Last lines of autoinst-log.txt:\n" . _mask(_log_since(0)),
#         };
#     }

#     my $failures = grep { $_->{status} eq 'failed' } @STEPS;
#     my $total = 0;
#     $total += $_->{duration} for @STEPS;

#     my $xml = sprintf qq{<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n}
#       . qq{<testsuite name="%s" tests="%d" failures="%d" time="%.3f">\n},
#       xml_escape($suite), scalar @STEPS, $failures, $total;

#     for my $s (@STEPS) {
#         my $failed = $s->{status} eq 'failed';
#         my @out    = @{$s->{actions} // []};
#         push @out, "ERROR: $s->{reason}" if $failed;

#         my $details = "at $s->{location}\nDetails: $s->{error}";
#         if ($failed && $s->{last_cmd}) {
#             my $c        = $s->{last_cmd};
#             my $cmd_out  = length($c->{output}) ? _clean_len($c->{output}, $MAX_CMD_OUTPUT) : '(no output)';
#             my $cmd_text = "\$ $c->{cmd}\nexit code: $c->{rc}\n$cmd_out";
#             push @out, '', $cmd_text;
#             $details = $cmd_text;    # сама команда/код/вывод важнее внутреннего Perl-текста ошибки
#         }
#         elsif ($failed && length($s->{log_excerpt} // '')) {
#             push @out, '', '--- autoinst-log.txt (excerpt for this step) ---', $s->{log_excerpt};
#         }
#         my $out = _clean(join "\n", @out);

#         my $body = '';
#         if ($failed) {
#             my ($msg) = split /\n/, $s->{reason};
#             $body .= sprintf qq{    <failure message="%s" type="StepFailure">%s</failure>\n},
#               xml_escape(_clean($msg)), xml_escape(_clean($details));
#         }
#         $body .= sprintf "    <system-out>%s</system-out>\n", xml_escape($out) if length $out;

#         my $attrs = sprintf 'classname="%s" name="%s" file="%s" time="%.3f"',
#           xml_escape($suite), xml_escape(_clean($s->{name})), xml_escape($s->{location}), $s->{duration};
#         $xml .= length $body ? "  <testcase $attrs>\n$body  </testcase>\n" : "  <testcase $attrs />\n";
#     }
#     $xml .= "</testsuite>\n</testsuites>\n";

#     my $dir = path('ulogs')->make_path;
#     $dir->child("junit-$suite.xml")->spew(encode('UTF-8', $xml));
#     $dir->child("steps-$suite.json")->spew(encode_json({suite => $suite, steps => \@STEPS}));
#     diag("[STEP] report written: ulogs/junit-$suite.xml, ulogs/steps-$suite.json");
#     return;
# }

# 1;

# package StepReport;

# Записывает шаги теста и в конце сохраняет их как артефакты job'а:
#   steps-<suite>.json  - источник правды (шаги, действия, ошибки, фрагмент autoinst-log.txt)
#   junit-<suite>.xml   - JUnit для CI (testcase = шаг, system-out = журнал действий)
#
# Использование в тесте:
#   use StepReport;
#   step 'P1. Network setup' => sub {
#       step_log "Activating connection ens4-static";          # что делаем (английское описание)
#       assert_script_run "nmcli con up ens4-static";
#   }, fail => 'Could not bring the static connection up';    # необязательно: своя причина ошибки
#   sub post_fail_hook { write_step_report('ssh_client', failed => 1) }
#   sub post_run_hook  { write_step_report('ssh_client') }
#
# Причина ошибки:
#   - если задан fail => '...', берётся он;
#   - иначе "Failed while: <последнее step_log шага>";
#   - подробный текст ошибки идёт отдельно (Details).

# use strict;
# use warnings;
# no warnings 'once';
# use Exporter 'import';
# use Time::HiRes 'time';
# use Mojo::JSON 'encode_json';
# use Mojo::File 'path';
# use Mojo::Util qw(xml_escape encode decode);
# use testapi;

# our @EXPORT = qw(step step_log write_step_report add_step_secret);

# my @STEPS;                        # шаги текущего job'а (живут в памяти isotovideo)
# my $CURRENT;                      # запись выполняющегося шага
# my @SECRETS;                      # значения, которые нельзя выводить в отчёт
# my $LOG            = 'autoinst-log.txt';
# my $MAX_LOG_LINES  = 80;
# my $MAX_TEXT_CHARS = 20000;

# sub add_step_secret { push @SECRETS, grep { defined && length } @_; return }

# # Маскируем пароли: значения переменных *PASSWORD*/*SECRET*/*TOKEN*, $testapi::password и всё из add_step_secret.
# sub _mask {
#     my ($s) = @_;
#     return $s unless defined $s && length $s;
#     my @secrets = @SECRETS;
#     push @secrets, $testapi::password if defined $testapi::password;
#     for my $k (keys %bmwqemu::vars) {
#         push @secrets, $bmwqemu::vars{$k} if $k =~ /PASSWORD|SECRET|TOKEN/ && defined $bmwqemu::vars{$k};
#     }
#     for my $sec (sort { length $b <=> length $a } grep { defined && length > 3 } @secrets) {
#         $s =~ s/\Q$sec\E/****/g;
#     }
#     return $s;
# }

# # Убираем управляющие символы (ANSI и т.п.): они делают XML невалидным. Ограничиваем размер.
# sub _clean {
#     my ($s) = @_;
#     $s //= '';
#     $s =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g;
#     $s = substr($s, -$MAX_TEXT_CHARS) if length $s > $MAX_TEXT_CHARS;
#     return $s;
# }

# # Всё, что isotovideo записал в autoinst-log.txt начиная с байтовой позиции $pos (последние N строк).
# sub _log_since {
#     my ($pos) = @_;
#     return '' unless -f $LOG;
#     open my $fh, '<:raw', $LOG or return '';
#     seek $fh, $pos, 0;
#     local $/;
#     my $txt = <$fh> // '';
#     close $fh;
#     my $dec = decode('UTF-8', $txt);
#     $txt = $dec if defined $dec;
#     my @lines = split /\n/, $txt;
#     splice @lines, 0, @lines - $MAX_LOG_LINES if @lines > $MAX_LOG_LINES;
#     return join "\n", @lines;
# }

# # Описание действия внутри шага: идёт в autoinst-log.txt и в журнал шага.
# sub step_log {
#     my ($msg) = @_;
#     $msg = _mask($msg);
#     diag("[STEP] $msg");
#     push @{$CURRENT->{actions}}, $msg if $CURRENT;
#     return;
# }

# sub step {
#     my ($name, $code, %opt) = @_;
#     my ($file, $line) = (caller)[1, 2];
#     $file =~ s{^.*/(?=(?:tests|lib)/)}{};
#     my $where   = "$file:$line";
#     my $log_pos = (-s $LOG) || 0;
#     my $start   = time;
#     my $rec     = {name => $name, status => 'passed', start => $start, location => $where, actions => []};
#     diag("[STEP] START: $name");

#     my $prev = $CURRENT;
#     $CURRENT = $rec;
#     my $ok  = eval { $code->(); 1 };
#     my $err = $@ || 'unknown error';
#     $CURRENT = $prev;
#     $rec->{duration} = time - $start;

#     unless ($ok) {
#         my $last = $rec->{actions}[-1];
#         $rec->{status}      = 'failed';
#         $rec->{reason}      = _mask($opt{fail} // (defined $last ? "Failed while: $last" : "Step '$name' failed"));
#         $rec->{error}       = _mask("$err");
#         $rec->{log_excerpt} = _mask(_log_since($log_pos));
#     }
#     push @STEPS, $rec;

#     diag(sprintf '[STEP] %s: %s (%.1fs)', $ok ? 'PASS' : 'FAIL', $name, $rec->{duration});
#     return 1 if $ok;
#     diag("[STEP] REASON: $rec->{reason}");
#     record_info("FAIL: $name", "$where\n$rec->{reason}\n\n$rec->{error}", result => 'fail');
#     die $err;
# }

# sub write_step_report {
#     my ($suite, %opt) = @_;
#     $suite //= get_var('TEST', 'openqa');

#     # Тест упал вне шага (например, в barrier_wait): без этого отчёт остался бы зелёным.
#     if ($opt{failed} && !grep { $_->{status} eq 'failed' } @STEPS) {
#         my $after = @STEPS ? "after step '$STEPS[-1]{name}'" : 'before the first step';
#         push @STEPS, {
#             name     => 'Failure outside of a step', status => 'failed', start => time, duration => 0,
#             location => 'n/a', actions => [],
#             reason   => "Test stopped unexpectedly outside of any step $after (for example in barrier_wait)",
#             error    => "Last lines of autoinst-log.txt:\n" . _mask(_log_since(0)),
#         };
#     }

#     my $failures = grep { $_->{status} eq 'failed' } @STEPS;
#     my $total = 0;
#     $total += $_->{duration} for @STEPS;

#     my $xml = sprintf qq{<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n}
#       . qq{<testsuite name="%s" tests="%d" failures="%d" time="%.3f">\n},
#       xml_escape($suite), scalar @STEPS, $failures, $total;

#     for my $s (@STEPS) {
#         my $failed = $s->{status} eq 'failed';
#         my @out    = @{$s->{actions} // []};
#         push @out, "ERROR: $s->{reason}" if $failed;
#         push @out, '', '--- autoinst-log.txt (excerpt for this step) ---', $s->{log_excerpt}
#           if $failed && length($s->{log_excerpt} // '');
#         my $out = _clean(join "\n", @out);

#         my $body = '';
#         if ($failed) {
#             my ($msg) = split /\n/, $s->{reason};
#             $body .= sprintf qq{    <failure message="%s" type="StepFailure">%s</failure>\n},
#               xml_escape(_clean($msg)), xml_escape(_clean("at $s->{location}\nDetails: $s->{error}"));
#         }
#         $body .= sprintf "    <system-out>%s</system-out>\n", xml_escape($out) if length $out;

#         my $attrs = sprintf 'classname="%s" name="%s" file="%s" time="%.3f"',
#           xml_escape($suite), xml_escape(_clean($s->{name})), xml_escape($s->{location}), $s->{duration};
#         $xml .= length $body ? "  <testcase $attrs>\n$body  </testcase>\n" : "  <testcase $attrs />\n";
#     }
#     $xml .= "</testsuite>\n</testsuites>\n";

#     my $dir = path('ulogs')->make_path;
#     $dir->child("junit-$suite.xml")->spew(encode('UTF-8', $xml));
#     $dir->child("steps-$suite.json")->spew(encode_json({suite => $suite, steps => \@STEPS}));
#     diag("[STEP] report written: ulogs/junit-$suite.xml, ulogs/steps-$suite.json");
#     return;
# }

# 1;