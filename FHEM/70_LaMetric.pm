###############################################################################
#
# A module to send notifications to LaMetric.
#
# written 2017 by Matthias Kleine <info at haus-automatisierung.com>
#
###############################################################################
#
# Also see API documentation:
# https://developer.lametric.com/
# http://lametric-documentation.readthedocs.io/en/latest/reference-docs/device-notifications.html

# {
#  "priority": "[info|warning|critical]",
#  "icon_type": "[none|info|alert]",
#  "lifeTime": <milliseconds>,
#  "model": {
#   "frames": [
#    {
#       "icon": "<icon id or base64 encoded binary>",
#       "text": "<text>"
#    },
#    {
#      "icon": "i298",
#      "text": "text"
#    },
#    {
#        "icon": "i120",
#        "goalData": {
#            "start": 0,
#            "current": 50,
#            "end": 100,
#            "unit": "%"
#        }
#    },
#    {
#        "chartData": [ <comma separated integer values> ]
#    }
#    ],
#    "sound": {
#      "category": "[alarms|notifications]",
#      "id": "<sound_id>",
#      "repeat": <repeat count>
#    },
#    "cycles": <cycle count>
#  }
#}

package main;

use HttpUtils;
use utf8;
use Data::Dumper;
use HttpUtils;
use SetExtensions;
use Encode;
use JSON qw(decode_json);

no if $] >= 5.017011, warnings => 'experimental';

my %sets = ("msg" => 1, "chart" => 1, "volume" => 1, "brightness" => 1, "app" => 1, "refresh" => 1);

#------------------------------------------------------------------------------
sub LaMetric_Initialize($$) {
    my ($hash) = @_;

    $hash->{DefFn} = "LaMetric_Define";
    $hash->{UndefFn} = "LaMetric_Undefine";
    $hash->{SetFn} = "LaMetric_Set";
    $hash->{AttrList} = "disable:0,1 defaultIcon notificationLifeTime " . $readingFnAttributes;
}

#------------------------------------------------------------------------------
sub LaMetric_Define($$) {
    my ($hash, $def) = @_;

    my @args = split("[ \t]+", $def);

    return "Invalid number of arguments: define <name> LaMetric <ip> <apikey> [<port>]" if (int(@args) < 2);

    my ($name, $type, $ip, $apikey, $port) = @args;

    if (defined($ip) && defined($apikey)) {

        return "$apikey does not seem to be a valid key" if ($apikey !~ /^([a-f0-9]{64})$/);

        $hash->{IP} = $ip;
        $hash->{API_KEY} = $apikey;
        $hash->{MODULE_VERSION} = "1.2";

        if (defined($port) && $port ne "") {
            $hash->{PORT} = $port;
        } else {
            $hash->{PORT} = 8080;
        }

        # start Validation Timer
        RemoveInternalTimer($hash);
        InternalTimer(gettimeofday() + 2, "LaMetric_CheckState", $hash, 0);

        return undef;
    }
    else {
        return "IP or ApiKey missing";
    }
}

#------------------------------------------------------------------------------
sub LaMetric_Undefine($$) {
    my ($hash, $name) = @_;

    RemoveInternalTimer($hash);

    return undef;
}

#------------------------------------------------------------------------------
sub LaMetric_Set($@) {
    my ($hash, $name, $cmd, @args) = @_;
    my ($a, $h) = parseParams(join " ", @args);

    if (!defined($sets{$cmd})) {
        return "Unknown argument " . $cmd . ", choose one of " . join(" ", sort keys %sets);
    }

    return "Unable to send message: Device is disabled" if (IsDisabled($name));

    return LaMetric_SetVolume($hash, @args) if ($cmd eq 'volume');
    return LaMetric_SetBrightness($hash, @args) if ($cmd eq 'brightness');
    return LaMetric_SetChart($hash, @args) if ($cmd eq 'chart');
    return LaMetric_SetMessage($hash, @args) if ($cmd eq 'msg');
    return LaMetric_SetApp($hash, @args) if ($cmd eq 'app');
    return LaMetric_CheckState($hash, @args) if ($cmd eq 'refresh');
}

#------------------------------------------------------------------------------
sub LaMetric_SendCommand {
    my ($hash, $service, $httpMethod, $data) = @_;

    my $apiKey          = $hash->{API_KEY};
    my $name            = $hash->{NAME};
    my $address         = $hash->{IP};
    my $port            = $hash->{PORT};
    my $apiVersion      = "v2";
    my $httpNoShutdown  = (defined($attr{$name}{"http-noshutdown"}) && $attr{$name}{"http-noshutdown"} eq "0") ? 0 : 1;
    my $timeout         = 3;

    $data = (defined($data)) ? $data : "";

    Log3 $name, 5, "LaMetric $name: called function LaMetric_SendCommand()";

    my $url;
    my $auth = encode_base64('dev:' . $apiKey, "");

    $url = "http://". $address . ":" . $port . "/api/" . $apiVersion . "/" . $service;

    if ($httpMethod eq "") {
        $httpMethod = "GET";
    }

    # Append GET-String if method is GET
    if ($httpMethod eq "GET") {
        $url .= "?" . $data;
        $data = undef;
    }

    if ($httpMethod) {
        # send request via HTTP-GET method

        Log3 $name, 5, "LaMetric $name: " . httpMethod . " " . urlDecode($url) . " (DATA: " . $data . " (noshutdown=" . $httpNoShutdown . ")";

        HttpUtils_NonblockingGet(
            {
                method     => $httpMethod,
                url        => $url,
                timeout    => $timeout,
                noshutdown => $httpNoShutdown,
                data       => $data,
                hash       => $hash,
                service    => $service,
                header     => "Authorization: Basic " . $auth,
                callback   => \&LaMetric_ReceiveCommand,
            }
        );

    } else {
        # other HTTP methods are not supported

        Log3 $name, 1, "LaMetric $name: ERROR: HTTP method " . $httpMethod . " is not supported.";
    }

    return;
}

#------------------------------------------------------------------------------
sub LaMetric_ReceiveCommand($$$) {
    my ($param, $err, $data) = @_;

    my $hash    = $param->{hash};
    my $name    = $hash->{NAME};

    my $method  = $param->{method};
    my $service = $param->{service};
    my $code    = $param->{code};
    my $state   = ReadingsVal($name, "state", "initialized");
    my $result  = ();

    Log3 $name, 5, "LaMetric $name: called function LaMetric_ReceiveCommand() for: " . $service;

    readingsBeginUpdate($hash);

    # service not reachable
    if ($err) {
        $state = "disconnected";
    } elsif ($data) {
        $state = "connected";

        $result = "ok";

        if ($code == 200 || $code == 201) {
            $state = "connected";

            if ($service eq "device") {
                my $deviceData = decode_json($data);

                readingsBulkUpdateIfChanged($hash, "deviceName", $deviceData->{name});
                readingsBulkUpdateIfChanged($hash, "deviceSerialNumber", $deviceData->{serial_number});
                readingsBulkUpdateIfChanged($hash, "deviceOsVersion", $deviceData->{os_version});
                readingsBulkUpdateIfChanged($hash, "deviceMode", $deviceData->{mode});
                readingsBulkUpdateIfChanged($hash, "deviceModel", $deviceData->{model});

                readingsBulkUpdateIfChanged($hash, "audioVolume", $deviceData->{audio}->{volume});

                readingsBulkUpdateIfChanged($hash, "bluetoothAvailable", $deviceData->{bluetooth}->{available});
                readingsBulkUpdateIfChanged($hash, "bluetoothName", $deviceData->{bluetooth}->{name});
                readingsBulkUpdateIfChanged($hash, "bluetoothActive", $deviceData->{bluetooth}->{active});
                readingsBulkUpdateIfChanged($hash, "bluetoothDiscoverable", $deviceData->{bluetooth}->{discoverable});
                readingsBulkUpdateIfChanged($hash, "bluetoothPairable", $deviceData->{bluetooth}->{pairable});
                readingsBulkUpdateIfChanged($hash, "bluetoothAddress", $deviceData->{bluetooth}->{address});

                readingsBulkUpdateIfChanged($hash, "displayBrightness", $deviceData->{display}->{brightness});
                readingsBulkUpdateIfChanged($hash, "displayBrightnessMode", $deviceData->{display}->{brightness_mode});

                readingsBulkUpdateIfChanged($hash, "wifiActive", $deviceData->{wifi}->{active});
                readingsBulkUpdateIfChanged($hash, "wifiAddress", $deviceData->{wifi}->{address});
                readingsBulkUpdateIfChanged($hash, "wifiAvailable", $deviceData->{wifi}->{available});
                readingsBulkUpdateIfChanged($hash, "wifiEncryption", $deviceData->{wifi}->{encryption});
                readingsBulkUpdateIfChanged($hash, "wifiEssid", $deviceData->{wifi}->{essid});
                readingsBulkUpdateIfChanged($hash, "wifiIp", $deviceData->{wifi}->{ip});
                readingsBulkUpdateIfChanged($hash, "wifiMode", $deviceData->{wifi}->{mode});
                readingsBulkUpdateIfChanged($hash, "wifiNetmask", $deviceData->{wifi}->{netmask});
                readingsBulkUpdateIfChanged($hash, "wifiStrength", $deviceData->{wifi}->{strength});
            } else {
                $result = $data;

                # Update other values
                LaMetric_CheckState($hash, @_);
            }
        } else {
            $state = "error";
            $result = "Server Error " . $param->{code};
        }

        readingsBulkUpdate($hash, "lastCommand", $service . " (" . $method . ")");
        readingsBulkUpdate($hash, "lastResult", $result);
    }

    # Set reading for state
    readingsBulkUpdateIfChanged($hash, "state", $state);

    readingsEndUpdate($hash, 1);

    return;
}

#------------------------------------------------------------------------------
sub LaMetric_CheckState($;$) {
    my ($hash, $update) = @_;

    my $name = $hash->{NAME};
    my $ip = $hash->{IP};

    Log3 $name, 5, "LaMetric $name: called function LaMetric_CheckState()";

    RemoveInternalTimer($hash);

    if (AttrVal($name, "disable", 0) == 1) {
        # Retry in 600 seconds
        InternalTimer(gettimeofday() + 600, "LaMetric_CheckState", $hash, 0);

        return;
    } else {
        LaMetric_SendCommand($hash, "device", "GET", "");

        InternalTimer(gettimeofday() + 60, "LaMetric_CheckState", $hash, 0);
    }

    return;
}

#------------------------------------------------------------------------------
sub LaMetric_SetBrightness {
    my $hash   = shift;
    my $name   = $hash->{NAME};
    my %values = ();

    Log3 $name, 5, "LaMetric $name: called function LaMetric_SetBrightness()";

    my ($brightness) = @_;

    if ($brightness) {
        my $body;

        if (looks_like_number($brightness)) {
            $body = '{ "brightness": ' . $brightness . ', "brightness_mode": "manual" }';
        } else {
            $body = '{ "brightness_mode": "' . $brightness . '" }';
        }

        LaMetric_SendCommand($hash, "device/display", "PUT", $body);

        return;
    } else {
        # There was a problem with the arguments
        return "Syntax: set $name brightness 1-100|auto|manual";
    }
}

#------------------------------------------------------------------------------
sub LaMetric_SetVolume {
    my $hash   = shift;
    my $name   = $hash->{NAME};
    my %values = ();

    Log3 $name, 5, "LaMetric $name: called function LaMetric_SetVolume()";
    
    my ($volume) = @_;

    if (looks_like_number($volume)) {
        my $body;

        $body = '{ "volume": ' . $volume . ' }';

        LaMetric_SendCommand($hash, "device/audio", "PUT", $body);

        return;
    } else {
        # There was a problem with the arguments
        return "Syntax: set $name volume 1-100";
    }
}

#------------------------------------------------------------------------------
sub LaMetric_SetChart {
    my $hash   = shift;
    my $name   = $hash->{NAME};

    Log3 $name, 5, "LaMetric $name: called function LaMetric_SetChart()";

    my $chartItems = join(", ", @_);
    my $lifeTime = AttrVal($hash->{NAME}, "notificationLifeTime", "60000");

    if ($chartItems) {
        my $body;

        $body = '{ "lifeTime": ' . $lifeTime . ', "model": { "frames": [ { "chartData": [ ' . $chartItems . ' ] } ] } }';

        LaMetric_SendCommand($hash, "device/notifications", "POST", $body);

        return;
    } else {
        # There was a problem with the arguments
        return "Syntax: set $name chart 1 2 3 4 5 6 ...";
    }
}

#------------------------------------------------------------------------------
sub LaMetric_SetApp {
    my $hash = shift;
    my $name = $hash->{NAME};

    my $command = $_[0];

    Log3 $name, 5, "LaMetric $name: called function LaMetric_SetApp() " . $command;

    if ($command eq "next" || $command eq "prev") {
        LaMetric_SendCommand($hash, "device/apps/" . $command, "PUT", "");

        return;
    } else {
        # There was a problem with the arguments
        return "Syntax: set $name app [next|prev]";
    }
}

#------------------------------------------------------------------------------
sub LaMetric_SetMessage {
    my $hash   = shift;
    my $name   = $hash->{NAME};
    my %values = ();

    Log3 $name, 5, "LaMetric $name: called function LaMetric_SetMessage()";

    #Set defaults
    $values{icon} = AttrVal($hash->{NAME}, "defaultIcon", "");
    $values{lifeTime} = AttrVal($hash->{NAME}, "notificationLifeTime", "60000");
    $values{message} = "";
    $values{sound} = "";
    $values{repeat} = "1";
    $values{cycles} = "1";

    #Split parameters
    my $param = join(" ", @_);
    my $argc = 0;

    if ($param =~ /(".*"|'.*')\s*(".*"|'.*')\s*(".*"|'.*')\s*(".*"|'.*')\s*(".*"|'.*')\s*$/s) {
        $argc = 5;
    } elsif ($param =~ /(".*"|'.*')\s*(".*"|'.*')\s*(".*"|'.*')\s*(".*"|'.*')\s*$/s) {
        $argc = 4;
    } elsif ($param =~ /(".*"|'.*')\s*(".*"|'.*')\s*(".*"|'.*')\s*$/s) {
        $argc = 3;
    } elsif ($param =~ /(".*"|'.*')\s*(".*"|'.*')\s*$/s) {
        $argc = 2;
    } elsif ($param =~ /(".*"|'.*')\s*$/s) {
        $argc = 1;
    }

    Log3 $name, 4, "LaMetric $name: Found $argc argument(s)";

    if ($argc == 1) {
        $values{message} = $1;
        Log3 $name, 4, "LaMetric $name: message = $values{message}";
    } else {
        $values{icon} = $1 if ($argc >= 1);
        $values{message} = $2 if ($argc >= 2);
        $values{sound} = $3 if ($argc >= 3);
        $values{repeat} = $4 if ($argc >= 4);
        $values{cycles} = $5 if ($argc >= 5);
    }

    #Remove quotation marks
    if ($values{icon} =~ /^['"]([i|a]{1}[0-9]{0,5})['"]$/s) {
        $values{icon} = $1;
    }
    if ($values{message} =~ /^['"](.*)['"]$/s) {
        $values{message} = $1;
    }
    if ($values{sound} =~ /^['"](alarms|notifications:.*)['"]$/s) {
        $values{sound} = $1;
    }
    if ($values{repeat} =~ /^['"]([0-9]{1,})['"]$/s) {
        $values{repeat} = $1;
    }
    if ($values{cycles} =~ /^['"]([0-9]{1,})['"]$/s) {
        $values{cycles} = $1;
    }

    # Check if all mandatory arguments are filled:
    # "message" and "icon" can not be empty
    if ($values{message} ne "" && $values{icon} ne "") {
        my $body;

        my $sound = "";

        if ($argc >= 3 && $values{sound} ne "") {
            my @sFields = split /:/, $values{sound};
            $sound = ', "sound": { "category": "' . $sFields[0] . '", "id": "' . $sFields[1] . '", "repeat": ' . $values{repeat} . ' }';
        }

        $body = '{ "lifeTime": ' . $values{lifeTime} . ', "model": { "frames": [ { "icon": "' . $values{icon} . '", "text": "' . $values{message} . '"} ] ' . $sound . ', "cycles": ' . $values{cycles} . ' } }';

        LaMetric_SendCommand($hash, "device/notifications", "POST", $body);

        return;
    } else {
        # There was a problem with the arguments

        if ($argc == 1 && $values{icon} eq "") {
            return "Please define the defaultIcon in the LaMetric device arguments.";
        } else {
            return "Syntax: set $name msg ['<icon>'] '<message>' ['notifications|alarms:sound'] ['repeat'] ['cycles']";
        }
    }
}

1;

###############################################################################

=pod
=item device
=item summary text message notification functionality for LaMetric time API
=item summary_DE Notification-Funktion f&uuml;r die LaMetric time &uuml;ber die offizielle Schnittstelle
=begin html

<a name="LaMetric"></a>
<h3>LaMetric</h3>
<ul>
  LaMetric is a smart clock with retro design, which can be used to display different information and is able to receive notifications.<br>
  You need an account to use this module.<br>
  For further information about the service please visit <a href="https://developer.lametric.com/">developer.lametric.com</a>.<br>
  <br>
  <br>
  <a name="LaMetricDefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; LaMetric &lt;ip&gt; &lt;apikey&gt; [&lt;port&gt;]</code><br>
    <br>
    Please create <a href="https://developer.lametric.com/">an account</a> to receive the api key.<br>
    You will find the api key in the account menu <i>My Devices</i><br>
    <br>
    The attribute port is optional. Port 8080 will be used by default.
    <br>
    Examples:
    <ul>
      <code>define lametric LaMetric 192.168.2.31 a20205cb7eace9c979c27fd55413296b8ac9dafbfb5dae2022a1dc6b77fe9d2d</code>
    </ul>
    <ul>
      <code>define lametric LaMetric 192.168.2.31 a20205cb7eace9c979c27fd55413296b8ac9dafbfb5dae2022a1dc6b77fe9d2d 8080</code>
    </ul>
  </ul>
  <br>
  <a name="LaMetricSet"></a>
  <b>Set</b>
  <ul><b>msg</b><ul>
    <code>set &lt;LaMetric_device&gt; msg '&lt;text&gt;'</code><br>
    <code>set &lt;LaMetric_device&gt; msg '&lt;icon&gt;' '&lt;text&gt;' '&lt;notifications|alarms&gt;:&lt;sound&gt;' '&lt;repeat&gt;' '&lt;cycles&gt;'</code>
    <br>
    <br>
    The following sounds can be used - all sounds will be played once. Repetition of sounds is not implemented:<br>
    <br>
    <ul>
        <li>notifications:bicycle</li>
        <li>notifications:car</li>
        <li>notifications:cash</li>
        <li>notifications:cat</li>
        <li>notifications:dog</li>
        <li>notifications:dog2</li>
        <li>notifications:energy</li>
        <li>notifications:knock-knock</li>
        <li>notifications:letter_email</li>
        <li>notifications:lose1</li>
        <li>notifications:lose2</li>
        <li>notifications:negative1</li>
        <li>notifications:negative2</li>
        <li>notifications:negative3</li>
        <li>notifications:negative4</li>
        <li>notifications:negative5</li>
        <li>notifications:notification</li>
        <li>notifications:notification2</li>
        <li>notifications:notification3</li>
        <li>notifications:notification4</li>
        <li>notifications:open_door</li>
        <li>notifications:positive1</li>
        <li>notifications:positive2</li>
        <li>notifications:positive3</li>
        <li>notifications:positive4</li>
        <li>notifications:positive5</li>
        <li>notifications:positive6</li>
        <li>notifications:statistic</li>
        <li>notifications:thunder</li>
        <li>notifications:water1</li>
        <li>notifications:water2</li>
        <li>notifications:win</li>
        <li>notifications:win2</li>
        <li>notifications:wind</li>
        <li>notifications:wind_short</li>
        <li>alarms:alarm1</li>
        <li>alarms:alarm2</li>
        <li>alarms:alarm3</li>
        <li>alarms:alarm4</li>
        <li>alarms:alarm5</li>
        <li>alarms:alarm6</li>
        <li>alarms:alarm7</li>
        <li>alarms:alarm8</li>
        <li>alarms:alarm9</li>
        <li>alarms:alarm10</li>
        <li>alarms:alarm11</li>
        <li>alarms:alarm12</li>
        <li>alarms:alarm13</li>
    </ul>
    <br>
    Examples:
    <ul>
      <code>set LaMetric1 msg 'Meine erste LaMetric Nachricht.'</code><br>
      <code>set LaMetric1 msg 'a76' 'gassi' 'notifications:dog'</code><br>
      <code>set LaMetric1 msg 'a76' 'gassi'</code>
    </ul>
  <br>
  <br>
    <code>set &lt;LaMetric_device&gt; brightness &lt;1-100&gt;</code><br>
    <code>set &lt;LaMetric_device&gt; brightness auto</code>
  <br>
  <br>
    <code>set &lt;LaMetric_device&gt; volume &lt;0-100&gt;</code><br>
  <br>
  <br>
    <code>set &lt;LaMetric_device&gt; chart 1 2 3 4 5 6 ...</code><br>
  <br>
  <br>
  <b>Get</b>
  <ul>
    <li>N/A</li>
  </ul>
  <br>
  <a name="LaMetricAttr"></a>
  <b>Attributes</b>
  <ul>
    <li>
        <a name="LaMetricAttrdefaultIcon"></a><code>defaultIcon</code><br>
        Set the Default-Icon which will be used when just the 'text' parameter is present in msg set.
    </li>
  </ul>
  <br>
  <a name="LaMetricEvents"></a>
  <b>Generated events:</b>
  <ul>
     <li>N/A</li>
  </ul>
</ul>

=end html
=begin html_DE

<a name="LaMetric"></a>
<h3>LaMetric</h3>
<ul>
  LaMetric ist eine smarte Uhr im Retro-Look, welche nicht nur viele Informationen darstellen, sondern auch Notifications empfangen kann.<br>
  Du brauchst einen Account um dieses Modul zu verwenden.<br>
  F&uuml;r weitere Informationen &uuml;ber den Dienst besuche <a href="https://developer.lametric.com/">developer.lametric.com</a>.<br>
  <br>
  <br>
  <a name="LaMetricDefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; LaMetric &lt;ip&gt; &lt;apikey&gt; [&lt;port&gt;]</code><br>
    <br>
    Du musst einen <a href="https://developer.lametric.com/">Account erstellen</a>, um den API-Key zu bekommen.<br>
    Diesen findest Du auf der Webseite unter dem Punkt <i>My Devices</i><br>
    <br>
    Das Attribut port ist optional. Standardmäßig wird der Port 8080 verwendet.
    <br>
    Beispiel:
    <ul>
      <code>define lametric LaMetric 192.168.2.31 a20205cb7eace9c979c27fd55413296b8ac9dafbfb5dae2022a1dc6b77fe9d2d</code>
    </ul>
    <ul>
      <code>define lametric LaMetric 192.168.2.31 a20205cb7eace9c979c27fd55413296b8ac9dafbfb5dae2022a1dc6b77fe9d2d 8080</code>
    </ul>
  </ul>
  <br>
  <a name="LaMetricSet"></a>
  <b>Set</b>
  <ul><b>msg</b><ul>
    <code>set &lt;LaMetric_device&gt; msg '&lt;text&gt;'</code><br>
    <code>set &lt;LaMetric_device&gt; msg '&lt;icon&gt;' '&lt;text&gt;' '&lt;notifications|alarms&gt;:&lt;sound&gt;' '&lt;repeat&gt;' '&lt;cycles&gt;'</code>
    <br>
    <br>
    Die folgenden Sounds k&ouml;nnen genutzt werden - diese werden aktuell nur 1x wiederholt:<br>
    <br>
    <ul>
        <li>notifications:bicycle</li>
        <li>notifications:car</li>
        <li>notifications:cash</li>
        <li>notifications:cat</li>
        <li>notifications:dog</li>
        <li>notifications:dog2</li>
        <li>notifications:energy</li>
        <li>notifications:knock-knock</li>
        <li>notifications:letter_email</li>
        <li>notifications:lose1</li>
        <li>notifications:lose2</li>
        <li>notifications:negative1</li>
        <li>notifications:negative2</li>
        <li>notifications:negative3</li>
        <li>notifications:negative4</li>
        <li>notifications:negative5</li>
        <li>notifications:notification</li>
        <li>notifications:notification2</li>
        <li>notifications:notification3</li>
        <li>notifications:notification4</li>
        <li>notifications:open_door</li>
        <li>notifications:positive1</li>
        <li>notifications:positive2</li>
        <li>notifications:positive3</li>
        <li>notifications:positive4</li>
        <li>notifications:positive5</li>
        <li>notifications:positive6</li>
        <li>notifications:statistic</li>
        <li>notifications:thunder</li>
        <li>notifications:water1</li>
        <li>notifications:water2</li>
        <li>notifications:win</li>
        <li>notifications:win2</li>
        <li>notifications:wind</li>
        <li>notifications:wind_short</li>
        <li>alarms:alarm1</li>
        <li>alarms:alarm2</li>
        <li>alarms:alarm3</li>
        <li>alarms:alarm4</li>
        <li>alarms:alarm5</li>
        <li>alarms:alarm6</li>
        <li>alarms:alarm7</li>
        <li>alarms:alarm8</li>
        <li>alarms:alarm9</li>
        <li>alarms:alarm10</li>
        <li>alarms:alarm11</li>
        <li>alarms:alarm12</li>
        <li>alarms:alarm13</li>
    </ul>
    <br>
    Beispiele:
    <ul>
      <code>set LaMetric1 msg 'Meine erste LaMetric Nachricht.'</code><br>
      <code>set LaMetric1 msg 'a76' 'gassi' 'notifications:dog'</code><br>
      <code>set LaMetric1 msg 'a76' 'gassi'</code>
    </ul>
  <br>
  <br>
    <code>set &lt;LaMetric_device&gt; brightness &lt;1-100&gt;</code><br>
    <code>set &lt;LaMetric_device&gt; brightness auto</code>
  <br>
  <br>
    <code>set &lt;LaMetric_device&gt; volume &lt;0-100&gt;</code><br>
  <br>
  <br>
    <code>set &lt;LaMetric_device&gt; chart 1 2 3 4 5 6 ...</code><br>
  <br>
  <br>
  <b>Get</b>
  <ul>
    <li>N/A</li>
  </ul>
  <br>
  <a name="LaMetricAttr"></a>
  <b>Attributes</b>
  <ul>
    <li>
        <a name="LaMetricAttrdefaultIcon"></a><code>defaultIcon</code><br>
        Setzt das Default-Icon, welches genutzt wird, wenn nur Text &uuml;bergeben wird.
    </li>
  </ul>
  <br>
  <a name="LaMetricEvents"></a>
  <b>Generated events:</b>
  <ul>
     <li>N/A</li>
  </ul>
</ul>

=end html_DE
=cut
