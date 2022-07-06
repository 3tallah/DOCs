function Test-StunEndpoint 
{
  param
  (
    [Parameter(Mandatory)]
    $UdpClient,
    [Parameter(Mandatory)]
    $StunEndpoint
  )
  $ipendpoint = $null
  try 
  {
    $UdpClient.client.ReceiveTimeout = 5000 
    $listenport = $UdpClient.client.localendpoint.port
    $endpoint = New-Object -TypeName System.Net.IPEndPoint -ArgumentList ([IPAddress]::Any, $listenport)

  
    [Byte[]] $payload = 
    0x00, 0x01, # Message Type: 0x0001 (Binding Request)
    0x00, 0x00, # Message Length: 0 bytes excluding header
    0x21, 0x12, 0xa4, 0x42 # Magic Cookie: Always 0x2112A442

    $LocalTransactionId = ([guid]::NewGuid()).ToByteArray()[1..12]
    $payload = $payload + $LocalTransactionId
    try 
    {
      $null = $UdpClient.Send($payload, $payload.length, $StunEndpoint)
    }
    catch 
    {
      throw "Unable to send data, check if $($StunEndpoint.AddressFamily) is configured"
    }
  
  
    try 
    {
      $content = $UdpClient.Receive([ref]$endpoint)
    }
    catch 
    {
      try 
      {
        $null = $UdpClient.Send($payload, $payload.length, $StunEndpoint)
        $content = $UdpClient.Receive([ref]$endpoint)
      }
      catch 
      {
        try 
        {
          $null = $UdpClient.Send($payload, $payload.length, $StunEndpoint)
          $content = $UdpClient.Receive([ref]$endpoint)
        }
        catch 
        {
          throw "Unable to receive data, check if firewall allows access to $($StunEndpoint.ToString())"
        }
      }
    }
    
    
    if (-not $content) 
    {
      throw  'Null response.'
    }
  
    [Byte[]]$messageType = $content[0..1]
    [Byte[]]$messageCookie = $content[4..7]
    [Byte[]]$TransactionId = $content[8..19]
    [Byte[]]$AttributeType = $content[20..21]
    [Byte[]]$AttributeLength = $content[22..23]

    if ([System.BitConverter]::IsLittleEndian) 
    {
      [Array]::Reverse($AttributeLength)
    }

    if ( -not ([BitConverter]::ToString($messageType)) -eq '01-01') 
    {
      throw  "Invalid message type: $([BitConverter]::ToString($messageType))"
    }
    if ( -not ([BitConverter]::ToString($messageCookie)) -eq '21-12-A4-42') 
    {
      throw  "Invalid message cookie: $([BitConverter]::ToString($messageCookie))"
    }
  
    if (-not  ([BitConverter]::ToString($TransactionId)) -eq [BitConverter]::ToString($LocalTransactionId) ) 
    {
      throw  "Invalid message id: $([BitConverter]::ToString($TransactionId))"
    }
    if (-not  ([BitConverter]::ToString($AttributeType)) -eq '00-20' ) 
    {
      throw  "Invalid Attribute Type: $([BitConverter]::ToString($AttributeType))"
    }
    $ProtocolByte = $content[25]
    if (-not (($ProtocolByte -eq 1) -or ($ProtocolByte -eq 2))) 
    {
      throw "Invalid Address Type: $([BitConverter]::ToString($ProtocolByte))"
    }
    $portArray = $content[26..27]
    if ([System.BitConverter]::IsLittleEndian) 
    {
      [Array]::Reverse($portArray)
    }

    $port = [Bitconverter]::ToUInt16($portArray, 0) -bxor 0x2112
          
    if ($ProtocolByte -eq 1) 
    {
      $IPbytes = $content[28..31]
      if ([System.BitConverter]::IsLittleEndian) 
      {
        [Array]::Reverse($IPbytes)
      }
      $IPByte = [System.BitConverter]::GetBytes(([Bitconverter]::ToUInt32($IPbytes, 0) -bxor 0x2112a442))
        
      if ([System.BitConverter]::IsLittleEndian) 
      {
        [Array]::Reverse($IPByte)
      }
      $IP = [ipaddress]::new($IPByte)
    }
    elseif ($ProtocolByte -eq 2) 
    {
      $IPbytes = $content[28..44]
      [Byte[]]$magic = $content[4..19]
      for ($i = 0; $i -lt $IPbytes.Count; $i ++) 
      {
        $IPbytes[$i] = $IPbytes[$i] -bxor $magic[$i]
      }
      $IP = [ipaddress]::new($IPbytes)
    }
    $ipendpoint = [IPEndpoint]::new($IP, $port)
  }
  catch 
  {
    Write-Host -Object "Failed to communicate $($StunEndpoint.ToString()) with error: $_" -ForegroundColor Red
  }
  return $ipendpoint
}


$UdpClient6 = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetworkV6)
$UdpClient = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)

  
$ipendpoint1 = Test-StunEndpoint -UdpClient $UdpClient -StunEndpoint ([IPEndpoint]::new(([Net.Dns]::GetHostAddresses('worldaz.turn.teams.microsoft.com')|Where-Object -FilterScript {$_.AddressFamily -EQ 'InterNetwork'})[0].Address, 3478))
$ipendpoint2 = Test-StunEndpoint -UdpClient $UdpClient -StunEndpoint ([IPEndpoint]::new([ipaddress]::Parse('13.107.17.41'), 3478))
$ipendpoint3 = Test-StunEndpoint -UdpClient $UdpClient6 -StunEndpoint ([IPEndpoint]::new([ipaddress]::Parse('2a01:111:202f::155'), 3478))


$localendpoint1 = $UdpClient.Client.LocalEndPoint
$localEndpoint2 = $UdpClient6.Client.LocalEndPoint


if ($null -ne $ipendpoint1) 
{
  if ($ipendpoint1.Port -eq $localendpoint1.Port) 
  {
    Write-Host  -Object 'Local NAT uses port preservation' -ForegroundColor Green
  }
  else 
  {
    Write-Host  -Object 'Local NAT does not use port preservation, custom port range may not work with Shortpath' -ForegroundColor Red
  }
  if ($null -eq $ipendpoint2) 
  {
    if ($ipendpoint1.Equals($ipendpoint2)) 
    {
      Write-Host -Object 'Local NAT reuses SNAT ports'  -ForegroundColor Green
    }
    else 
    {
      Write-Host -Object 'Local NAT does not reuse SNAT ports, preventing Shortpath from connecting this endpoint'  -ForegroundColor Red
    }
  }
}
Write-Output -InputObject "`nLocal endpoints:`n$localendpoint1`n$localEndpoint2"
Write-Output -InputObject "`nDiscovered external endpoints:`n$ipendpoint1`n$ipendpoint2`n$ipendpoint3`n"


$UdpClient.Close()
$UdpClient6.Close()


Pause
