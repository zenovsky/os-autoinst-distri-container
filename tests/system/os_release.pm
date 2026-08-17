use Mojo::Base 'basetest';
use testapi;

sub check_os_release {
    my (%args) = @_;

    foreach my $key (keys %args) {
        my $expected_value = $args{$key};

        # Экранируем кавычки, если есть
        $expected_value =~ s/"/\\"/g;

        # Команда для проверки через grep
        my $cmd = "grep -q '^$key=\"$expected_value\"' /etc/os-release";

        record_info("Check $key", "Expecting: $key=\"$expected_value\"");

        # Выполняем проверку
        assert_script_run($cmd, timeout => 10);
    }
}


sub run {
    my $os_name = get_var('OS_NAME');
    my $version = get_var('VERSION');


    check_os_release(
        NAME         => $os_name ,
        VERSION_ID     => $version
    );



}

1;