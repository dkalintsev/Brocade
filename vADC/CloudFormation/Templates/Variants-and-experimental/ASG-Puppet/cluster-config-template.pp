class { 'brocadevtm':
  rest_user   => 'admin',
  rest_pass   => '{{AdminPass}}',
  rest_ip     => '__vADC1PrivateIP__',
  rest_port   => 9070,
}


include brocadevtm::monitors_full_http

brocadevtm::pools { 'WebPool':
  ensure                                   => present,
  basic__monitors                          => '["Full HTTP"]',
  basic__nodes_table                       => '[{"node":"127.0.0.1:80","priority":1,"state":"active","weight":1}]',
  require                                  => [ Class[Brocadevtm::Monitors_full_http], ],
}


brocadevtm::ssl_server_keys { 'Example-Cert':
  ensure         => present,
  basic__private => '{{SSLPrivateKey}}',
  basic__public  => '{{SSLPublicKey}}',

}


brocadevtm::traffic_ip_groups { 'Web%20VIP':
  ensure                                  => present,
  basic__ipaddresses                      => '[{{TrafficIPs}}]',
  basic__machines                         => '[__vADCnDNS__]',
  basic__mode                             => 'ec2vpcelastic',
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

