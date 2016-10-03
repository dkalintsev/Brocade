class { 'brocadevtm':
  rest_user   => 'admin',
  rest_pass   => '{{AdminPass}}',
  rest_ip     => '{{vADC1PrivateIP}}',
  rest_port   => 9070,
}


class { 'brocadevtm::global_settings':
  cluster_comms__allowed_update_hosts         => '["all"]',
  fault_tolerance__auto_failback              => false,
  fault_tolerance__frontend_check_ips         => '[]',
  fault_tolerance__monitor_interval           => 2000,
  fault_tolerance__monitor_timeout            => 15,
  java__enabled                               => true,
}


include brocadevtm::monitors_full_http

brocadevtm::pools { 'WebPool':
  ensure                                   => present,
  basic__monitors                          => '["Full HTTP"]',
  basic__nodes_table                       => '[{"node":"{{WebServer1}}:80","priority":1,"state":"active","weight":1}]',
  require                                  => [ Class[Brocadevtm::Monitors_full_http], ],
}


brocadevtm::ssl_server_keys { 'Example-Cert':
  ensure         => present,
  basic__private => '{{SSLPrivateKey}}',
  basic__public  => '{{SSLPublicKey}}',

}


brocadevtm::traffic_ip_groups { 'Web%20VIP':
  ensure                                  => present,
  basic__ipaddresses                      => '["{{TrafficIP1}}","{{TrafficIP2}}"]',
  basic__machines                         => '["{{vADC1DNS}}","{{vADC2DNS}}"]',
  basic__mode                             => 'ec2vpcelastic',
}


brocadevtm::traffic_managers { '{{vADC1DNS}}':
  ensure                                 => present,
  basic__adminMasterXMLIP                => '{{vADC1PrivateIP}}',
  basic__adminSlaveXMLIP                 => '{{vADC1PrivateIP}}',
  basic__authenticationServerIP          => '{{vADC1PrivateIP}}',
  basic__cloud_platform                  => 'ec2',
  basic__numberOfCPUs                    => 1,
  basic__restServerPort                  => 11003,
  basic__updaterIP                       => '{{vADC1PrivateIP}}',
  appliance__licence_agreed              => true,
  appliance__ssh_password_allowed        => false,
  cluster_comms__external_ip             => 'EC2',
}


brocadevtm::traffic_managers { '{{vADC2DNS}}':
  ensure                                 => present,
  basic__adminMasterXMLIP                => '{{vADC2PrivateIP}}',
  basic__adminSlaveXMLIP                 => '{{vADC2PrivateIP}}',
  basic__authenticationServerIP          => '{{vADC2PrivateIP}}',
  basic__cloud_platform                  => 'ec2',
  basic__numberOfCPUs                    => 1,
  basic__restServerPort                  => 11003,
  basic__updaterIP                       => '{{vADC2PrivateIP}}',
  appliance__licence_agreed              => true,
  appliance__ssh_password_allowed        => false,
  cluster_comms__external_ip             => 'EC2',
}


brocadevtm::virtual_servers { 'WebService':
  ensure                                  => present,
  basic__enabled                          => true,
  basic__listen_on_any                    => false,
  basic__listen_on_traffic_ips            => '["Web VIP"]',
  basic__pool                             => 'WebPool',
  basic__port                             => 80,
  connection__timeout                     => 40,
  require                                 => [ Brocadevtm::Pools['WebPool'],  Brocadevtm::Traffic_ip_groups['Web%20VIP'], ],
}


brocadevtm::virtual_servers { 'WebService%20SSL':
  ensure                                  => present,
  basic__enabled                          => true,
  basic__listen_on_any                    => false,
  basic__listen_on_traffic_ips            => '["Web VIP"]',
  basic__pool                             => 'WebPool',
  basic__port                             => 443,
  basic__ssl_decrypt                      => true,
  connection__timeout                     => 40,
  ssl__ocsp_issuers                       => '[{"issuer":"_DEFAULT_","aia":true,"nonce":"off","required":"optional","responder_cert":"","signer":"","url":""}]',
  ssl__server_cert_default                => 'Example-Cert',
  require                                 => [ Brocadevtm::Pools['WebPool'],  Brocadevtm::Traffic_ip_groups['Web%20VIP'],  Brocadevtm::Ssl_server_keys['Example-Cert'], ],
}

