use strict;
use warnings;
use URI;
use JSON;
use Encode;
use URI::Escape qw/uri_unescape/;
use Plack::Request;
use AnyEvent::HTTP;
use WebService::Simple;
use WWW::YouTube::Download;
use Text::Xslate;
use Data::Dumper;
use Data::Section::Simple;
use Data::Recursive::Encode;

my $vpath  = Data::Section::Simple->new()->get_data_section();
my $tx     = Text::Xslate->new( path => [$vpath] );
my $client = WWW::YouTube::Download->new();

my $guard;
my %video_list;

#-------------------------------------------------------------------------

sub duration {
    my ($seconds) = @_;

    # second => minute
    my $minutes = int $seconds / 60;
    my $r_sec   =     $seconds % 60;

    # minute => hour
    my ($hour, $r_min);
    if ($minutes >= 60) {
        $hour  = int $minutes / 60;
        $r_min =     $minutes % 60;
    }
    $r_min = $minutes unless defined $r_min;

    return $hour ? sprintf("%02d:%02d:%02d", $hour, $r_min, $r_sec)
                 : sprintf("%02d:%02d", $r_min, $r_sec);
}

sub suffix {
    my $fmt = shift;
    return $fmt =~ /18|22|37/ ? '.mp4'
         : $fmt =~ /13|17/    ? '.3gp'
         :                      '.flv'
    ;
}

#-------------------------------------------------------------------------

sub get_video_list {
    my $param = shift;
    my $yt = WebService::Simple->new(
        base_url => 'http://gdata.youtube.com/feeds/api/videos',
        param    => $param,
    );
    my $res = $yt->get();
    return $res->parse_response();
}

sub get_video {
    my $video_id = shift;
    my $yt = WebService::Simple->new(
        base_url => "http://gdata.youtube.com/feeds/api/videos/$video_id"
    );
    my $res   = $yt->get();
    my $entry = $res->parse_response();
    return {
        video_id    => $video_id,
        category    => $entry->{'media:group'}->{'media:category'},
        player      => $entry->{'media:group'}->{'media:player'}->{'url'},
        title       => $entry->{'media:group'}->{'media:title'}->{'content'},
        thumbnail   => $entry->{'media:group'}->{'media:thumbnail'}->[0]->{'url'},
        description => $entry->{'media:group'}->{'media:description'}->{'content'},
        duration    => duration( $entry->{'media:group'}->{'yt:duration'}->{'seconds'} ),
    };

}

#-------------------------------------------------------------------------
sub _index {
    my $html = $tx->render('index.tx');
    return [200, [ 'Content-Type' => 'text/html' ], [ $html ]];
}

sub _search {
    my $req = shift;

    my $k       = $req->param('k');
    my $page    = $req->param('page') || 1;
    my $start_index = ($page - 1) * 25 + 1;
#    my $done    = get_video_list({ vq => $k, orderby => 'updated'});
    my $done    = get_video_list({ vq => $k, 'start-index' => 23 });
    my @entries = keys %{ $done->{entry} };

    my @body;
    for my $id (@entries) {
        my $entry    = $done->{entry}->{$id};
        my $uri      = URI->new( $entry->{'media:group'}->{'media:player'}->{'url'} );
        my %query    = map { split /=/ } split /&/, $uri->query;
        my $video_id = $query{'v'};

        push @body, {
            video_id    => $video_id,
            category    => $entry->{'media:group'}->{'media:category'},
            player      => $entry->{'media:group'}->{'media:player'}->{'url'},
            title       => $entry->{'media:group'}->{'media:title'}->{'content'},
            thumbnail   => $entry->{'media:group'}->{'media:thumbnail'}->[0]->{'url'},
            description => $entry->{'media:group'}->{'media:description'}->{'content'},
            duration    => duration( $entry->{'media:group'}->{'yt:duration'}->{'seconds'} ),
            published   => $entry->{'published'},
        };
    }

    return [ 200, [ 'Content-Type' => 'text/plain' ], [ encode_json \@body ]];
}

sub _format {
    my $req = shift;
    my $video_id = $req->param('video_id');
    $video_list{ $video_id } ||= $client->prepare_download($video_id);

    my $video_url_map = $video_list{ $video_id }->{video_url_map};
    my $video_list = [
        map  +{ fmt => $_, resolution => $video_url_map->{$_}->{resolution}, suffix => suffix($_) },
        sort  { $a <=> $b }
        keys %{ $video_url_map }
    ];

    return [
        200,
        [ 'Content-Type' => 'text/plain' ],
        [ encode_json +{
            video_id   => $video_id,
            video_list => $video_list,
        } ]
    ];
}

sub _download {
    my $req = shift;
    my $video_id = $req->param('video_id');
    my $fmt      = $req->param('fmt');

    $video_list{ $video_id } ||= $client->prepare_download($video_id);
    my $url       = $video_list{ $video_id }->{video_url_map}->{$fmt}->{url};
    my $file_name = $video_list{ $video_id }->{title}.suffix($fmt);

    $video_list{ $video_id }->{cv} = AnyEvent->condvar;
    return sub {
        my $respond = shift;
        
        $video_list{ $video_id }->{cv}->cb(sub {
            my $res = $video_list{ $video_id }->{cv}->recv;
            $respond->($res);
            delete $video_list{ $video_id };
        });

        open my $fh, '>', $file_name or die $!;
        binmode($fh);

        $video_list{ $video_id }->{guard} = http_get $url,
           on_body => sub {
                my ($body, $headers) = @_;
                $video_list{ $video_id }->{total} ||= $headers->{'content-length'};

                print $fh $body;
                $video_list{ $video_id }->{size} = tell $fh;

           },
           cb => sub {
               my ($body, $headers) = @_;

               my $res = [200, ['Content-Type' => 'text/plain'], [ encode_json { video_id => $video_id } ]];
               $video_list{ $video_id }->{cv}->send($res);
           };
    };
}

sub _check {
    my $req = shift;
    my $video_id = $req->param('video_id');
    my $current_size = $video_list{ $video_id }->{size};
    my $total        = $video_list{ $video_id }->{total};
    my $percent      = $total ? sprintf("%.01f", $current_size / $total  * 100) : 0.0;        

    return [
        200,
        [ 'Content-Type' => 'text/plain' ],
        [ encode_json {
            video_id     => $video_id,
            current_size => $current_size, 
            total        => $total, 
            percent      => $percent,
        } ]
    ];
}

sub _cancel {
    my $req = shift;
    my $video_id = $req->param('video_id');
    delete $video_list{ $video_id };

    return [200, ['Content-Type' => 'text/plain'], [ encode_json { video_id => $video_id } ]];
}

my $app = sub {
    my $env = shift;
    my $req = Plack::Request->new($env);
    if ($req->path eq '/') {
        return _index($req);
    }
    elsif ($req->path eq '/search') {
        return _search($req);
    }
    elsif ($req->path eq '/format') {
        return _format($req);
    }
    elsif ($req->path eq '/download') {
        return _download($req);
    }
    elsif ($req->path eq '/cancel') {
        return _cancel($req);
    }
    elsif ($req->path eq '/check') {
        return _check($req);
    }
    else {
        return [ 404, [ 'Content-Type' => 'text/plain' ], [ 'not found' ]];
    }
}
__DATA__
@@ index.tx
<html>
<head>
<title>Youtube</title>
<script type="text/javascript" src="http://ajax.googleapis.com/ajax/libs/jquery/1.4.4/jquery.min.js"></script>
<script type="text/javascript" src="http://ajax.googleapis.com/ajax/libs/jqueryui/1.8.9/jquery-ui.min.js"></script>
<script type="text/javascript" src="http://ajax.googleapis.com/ajax/libs/swfobject/2.2/swfobject.js"></script>
<script type="text/javascript">

/*-----------------------------------------------*/
/* check */
/*-----------------------------------------------*/
var check_timer = {};
function check(video_id) {
   $.ajax({
       url      : '/check',
       data     : {video_id : video_id},
       dataType : 'json',
       success  : function(data) {
            if (!$("#download_" + video_id).size()) {
                var thumbnail = $("#" + video_id + ">img").attr('src'); 
                var title     = $("#" + video_id + ">span.title").text();
                var duration  = $("#" + video_id + ">span.duration").text();
                $("#download_list").append(
                    $('<div />').attr({id : "download_" + data.video_id})
                                .append( $('<img />').attr({src : thumbnail, class:'thumbnail'}) )
                                .append( $('<span />').attr({class: 'title'}).append(title) ).append( '<br />' )
                                .append( $('<span />').attr({class: 'duration'}).append(duration) ).append( '<br />' )
                                .append( $('<a />').attr({href : '/cancel?video_id=' + data.video_id, class : 'cancel'}).append('cancel') )
                                .append( $('<div />').attr({id: 'progress_' + data.video_id}) )
                                .append( $('<br />').attr({class : 'clear'}) )
                                .append( '<hr />' )
                );
            }
            else {
               $("#progress_" + data.video_id).text(data.percent + '%');
            }
       },
       complete : function() {
           check_timer[video_id] = setTimeout(function() { check(video_id) }, 3000);
       }
   });
}

/*-----------------------------------------------------------------------------------------------------*/
$(document).ready(function(){

    /*-----------------------------------------------*/
    /* search */
    /*-----------------------------------------------*/
    $("#search").click(function(){
        if (!$("#k").val()) {
            return false;
        }

        $.ajax({
            url      : '/search',
            data     : { k : $("#k").val() },
            dataType : 'json',
            success  : function(data) {
                $("#search_list>div").empty(''); // clear

                for (var i=0; i<data.length; i++) {

                    $("#search_list").append(
                        $('<div />').attr({id : data[i].video_id})
                                    .append( $('<img />').attr({src : data[i].thumbnail, class:'thumbnail'}) )
                                    .append( $('<span />').attr({class: 'title'}).append(data[i].title) ).append( '<br />' )
                                    .append( $('<span />').attr({class: 'duration'}).append(data[i].duration) ).append( '<br />' )
                                    .append( $('<a />').attr({href : '/format?video_id=' + data[i].video_id, class : 'format'}).append('format list') )
                                    .append( $('<div />').attr({id : 'format_list_' + data[i].video_id}) )
                                    .append( $('<br />').attr({class : 'clear'}) )
                                    .append( '<hr />' )
                    );
                }
            }
        });
        return false;
    });

    /*-----------------------------------------------*/
    /* download */
    /*-----------------------------------------------*/
    $(".download").live('click', function() {
        var video_id;
        var url   = $(this).attr('href').split('?');
        var query = url[1].split('&');
        for (var i=0; i<query.length; i++) {
            var key_value = query[i].split('=');
            if (key_value[0] === 'video_id') {
                video_id = key_value[1];
                break;
            }
        }

        check(video_id);
        $.ajax({
            url      : $(this).attr('href'),
            dataType :'json',
            success  : function(data) {
                $("#download_" + video_id).remove();
            },
            complete : function() {
                clearTimeout(check_timer[video_id]);
            }
        });
        return false;
    });

    /*-----------------------------------------------*/
    /* cancel */
    /*-----------------------------------------------*/
    $(".cancel").live("click", function() {
        $.ajax({
            url      : $(this).attr('href'),
            dataType : 'json',
            success  : function(data) {
                if (data.video_id) {
                    $("#download_" + data.video_id).remove();
                    clearTimeout(check_timer[data.video_id]);
                }
            },
        });
        return false;
    });

    /*-----------------------------------------------*/
    /* format */
    /*-----------------------------------------------*/
    $(".format").live("click", function() {

       $.ajax({
           url      : $(this).attr('href'),
           dataType : 'json',
           success  : function(data) {

                if (!$("#format_" + data.video_id).size()) {

                    for (var i=0; i<data.video_list.length; i++) {
                        var fmt = data.video_list[i].fmt;
                        var ext = data.video_list[i].ext;
    
                        $("#format_list_" + data.video_id).append(
                            $('<div />').attr({id : "format_" + data.video_id})
                                        .append(
                                            $('<a />').attr({href : '/download?video_id='+ data.video_id +'&fmt='+ fmt, class:'download'}) 
                                                      .append(data.video_list[i].resolution + '(' + data.video_list[i].suffix + ')' ) )
                                        .append('<br />')
                        );
                    }
                }
           }
       }); 
      return false;
    });
});
</script>
<style type="text/css">
* {
    font-size: x-small;
}
.title {
    font-weight : bold;
}
.thumbnail {
    width :240px;
    height:180px;
    float :left;
}
.clear { clear:both }
.format_list {
    display: none;
}
#search_list {
    width   : 50%;
    float   : left;
    postion : relative;
}
#download_list {
    width : 50%;
    float : left;
}
</style>
</head>
<body>
<form name="search">
<input type="text" name="k" id="k" size="40" />
<input type="submit" value="search" id="search" />
</form>
<hr />
<div id="search_list">
<h2>search list</h2>
</div>
<div id="download_list">
<h2>download list</h2>
</div>
<div id="player"></div>
</body>
</html>
