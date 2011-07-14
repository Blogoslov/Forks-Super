# trivial external command to wait and then exit
$SIG{QUIT} = sub { 
    die "$$ received SIGQUIT\n";
};
sleep 15;
