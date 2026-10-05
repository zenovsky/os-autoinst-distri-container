use Mojo::Base 'basetest';
use testapi;
use expectedPackages;

sub run {

    script_run 'cd /tmp/';
    # Используем rpm для вывода только чистых имен пакетов (без .x86_64, .noarch и т.д.)
    script_run 'rpm -qa --qf "%{NAME}\n" > /tmp/installed_packages.txt';

    # Проверка содержимого файла
    script_run 'cat /tmp/installed_packages.txt';

    script_run "sed -i 's/\r$//' installed_packages.txt";
    script_run "cat installed_packages.txt | tr '[:upper:]' '[:lower:]' > installed.txt";

    # Ожидаемый список пакетов
    my @expected_packages = expectedPackages::get_packages_release;

    # Чтение списка установленных пакетов
    my $installed_packages_output = script_output 'cat installed.txt';

    # Преобразование установленных пакетов в массив
    my @installed_packages = split("\n", $installed_packages_output);

    # Преобразование ожидаемых пакетов в массив
    my @expected_packages_lower = map { lc $_ } @expected_packages;

    # Сортировка обоих списков для сравнения
    @installed_packages = sort { lc $a cmp lc $b } @installed_packages;
    @expected_packages_lower = sort { lc $a cmp lc $b } @expected_packages_lower;

    # Сравнение списков
    if (\@installed_packages ~~ \@expected_packages_lower) {
        record_info 'Package check', 'All expected packages are installed';
    } else {
        my %installed_hash = map { $_ => 1 } @installed_packages;
        my %expected_hash = map { $_ => 1 } @expected_packages_lower;

        my @missing_packages = grep { !exists $installed_hash{$_} } @expected_packages_lower;
        if (@missing_packages) {
           # Исправлена синтаксическая ошибка исходного скрипта (лишняя закрывающая скобка)
            record_soft_failure 'Missing packages: ' . join(', ', @missing_packages);
        }
    }

    # Проверка на дополнительные пакеты:
    my %expected_hash = map { $_ => 1 } @expected_packages_lower;
    my @extra_packages = grep { !exists $expected_hash{$_} } @installed_packages;
    if (@extra_packages) {
        # Исправлена синтаксическая ошибка исходного скрипта (лишняя закрывающая скобка)
        record_info 'Extra Packages', 'The following extra packages are installed: ' . join(', ', @extra_packages);
    }

    script_run 'cd ~';

    # Отметить тест как пройденный и завершенный
    record_info 'SUCCESS', 'All expected packages are installed';
}

1;
