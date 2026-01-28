let
  wan_gw="192.168.1.1";
  mgmt_gw="10.10.10.1";
  srv_gw="10.10.20.1";
  dmz_gw="10.10.30.1";
in
{
  MOTHER = { ip = "192.168.1.11"; mac = "70:88:88:88:6c:e1"; machineId = "f8883f0664be459f8312278bde07dd17"; isVm = false; gateway=wan_gw;} ;
  UCHI   = { ip = "192.168.1.20"; mac = "02:00:00:00:00:01"; machineId = "3692d4ba23994c3a818e8d577625d60c"; vsock_cid=3001; isVm=true; gateway=wan_gw;};
  SOTO   = { ip = "192.168.1.21"; mac = "02:00:00:00:00:02"; machineId = "056de0236c6346f795b053689ca0468f"; vsock_cid=3002; isVm=true; gateway=wan_gw;};
  KAIZOKU   = { ip = "192.168.1.22"; mac = "02:00:00:00:00:03"; machineId = "d7c79cedf4a24584ad28503505507e04"; vsock_cid=3003; isVm=true; gateway=wan_gw;};
  DARE   = { ip = "192.168.1.53"; mac = "02:00:00:00:00:53"; machineId = "332120c0300145b2b762d1db81546caf"; vsock_cid=3004; isVm=true; gateway=wan_gw;};
  OKAMI = { ip = "10.10.30.2"; mac = "02:00:00:00:01:01"; machineId = "72a6254779a04b32976185f178e50ea0"; vsock_cid=3005; isVm=true; gateway=dmz_gw; };
  MAMORU = { ip = "192.168.1.210"; mac="02:00:00:00:01:00"; isVm=true; machineId = "d13cdd34121748a997cfa8d4e2355da3"; vsock_cid=3006; gateway=wan_gw;};
  gateway = { ip = "192.168.1.1"; mac = null; isVm=false; gateway=null;};
}
