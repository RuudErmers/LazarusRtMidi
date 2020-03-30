unit URtMidi;

{$mode delphi}

interface

uses Classes, SysUtils, FileUtil, Forms, Controls, Graphics, Dialogs, StdCtrls, asoundlib;

type
    TMidiOutBuffer = array[0..31] of byte;
    TOnMidiInput = procedure(buffer:TMidiOutBuffer; size:integer) of object;
  TAlsaMidiData = class
    seq:Psnd_seq_t;
    vport,portNum:integer;
    subscription:Psnd_seq_port_subscribe_t;
    coder: Psnd_midi_event_t;
    buffer:TMidiOutBuffer;
  end;

  { TMidiOut }

  TMidiOut = class
  private
    Fconnected:boolean;
    Data:TAlsaMidiData;
    function portInfo(pinfo: Psnd_seq_port_info_t; _type,portnumber:integer ): integer;
    function lookupName(portName:string):integer;
  public
    function getPortCount:integer;
    function getPortName(portNumber:integer):string;
    procedure openPort(portName:string);
    procedure sendMessage(const message:TMidiOutBuffer; size:integer);
    procedure closePort;
    constructor Create;
  end;
  TMidiIn = class;
  TMidiInThread = class(TThread)
    FMidiIn:TMidiIn;
    procedure Execute; override;
    constructor Create(MidiIn:TMidiIn);
  end;

  { TMidiIn }

  TMidiIn = class
  private
    Fconnected:boolean;
    Data:TAlsaMidiData;
    ThreadTerminated:boolean;
    FThread:TMidiInThread;
    procedure InputThread;
    function portInfo(pinfo: Psnd_seq_port_info_t; _type,portnumber:integer ): integer;
    function lookupName(portName:string):integer;

  public
    { property }OnMidiInput: TOnMidiInput;
    function getPortCount:integer;
    function getPortName(portNumber:integer ):string;
    procedure openPort(portName:string);
    procedure initialize;
    procedure closePort;
    constructor create;
  end;


implementation

uses cthreads;

function TMidiOut.getPortCount:integer;
VAR pinfo:Psnd_seq_port_info_t;
begin
  snd_seq_port_info_malloc( @pinfo );
  result:=portInfo( pinfo, SND_SEQ_PORT_CAP_WRITE or SND_SEQ_PORT_CAP_SUBS_WRITE, -1 );
end;

function TMidiOut.portInfo(pinfo: Psnd_seq_port_info_t; _type,portnumber:integer ): integer;
VAR cinfo:Psnd_seq_client_info_t;
client,count,atyp,caps:integer;
begin
 count:=0;
  snd_seq_client_info_malloc( @cinfo );

  snd_seq_client_info_set_client( cinfo, -1 );
  while ( snd_seq_query_next_client( data.seq, cinfo ) >= 0 ) do
  begin
    client := snd_seq_client_info_get_client( cinfo );
    if ( client = 0 ) then continue;
    // Reset query info
    snd_seq_port_info_set_client( pinfo, client );
    snd_seq_port_info_set_port( pinfo, -1 );
    while ( snd_seq_query_next_port( data.seq, pinfo ) >= 0 ) do
    begin
      atyp := snd_seq_port_info_get_type( pinfo );
      if ( ( ( atyp AND SND_SEQ_PORT_TYPE_MIDI_GENERIC ) = 0 ) AND
           ( ( atyp AND SND_SEQ_PORT_TYPE_SYNTH ) = 0 ) AND
           ( ( atyp AND SND_SEQ_PORT_TYPE_APPLICATION ) =0 ) ) then continue;

      caps := snd_seq_port_info_get_capability( pinfo );
      if ( ( caps AND _type ) <> _type ) then continue;
      if ( count = portNumber ) then begin result:=1; exit; end;
      inc(count);
    end;
  //}
  end;

  // If a negative portNumber was used, return the port count.
  if ( portNumber < 0 ) then result:=count
  else result:=0;
end;

function TMidiOut.getPortName(portNumber:integer):string;
VAR
  cinfo: Psnd_seq_client_info_t ;
  pinfo: Psnd_seq_port_info_t;
  stringName:string;
  cnum:integer;

begin
  snd_seq_client_info_malloc( @cinfo );
  snd_seq_port_info_malloc( @pinfo );
  if portInfo( pinfo, SND_SEQ_PORT_CAP_READ or SND_SEQ_PORT_CAP_SUBS_READ, portNumber ) > 0 then
  begin
    cnum := snd_seq_port_info_get_client( pinfo );
    snd_seq_get_any_client_info( data.seq, cnum, cinfo );
    //client:=snd_seq_port_info_get_client( pinfo );
    //port:=snd_seq_port_info_get_port( pinfo );
    stringName:=snd_seq_client_info_get_name( cinfo );
    result:=stringName;
    exit;
  end;
  result:='NOP';
end;

function TMidiOut.lookupName(portName: string): integer;
VAR i:integer;
begin
  result:=-1;
  for i:=0 to getPortCount-1 do
    if 1=Pos(Uppercase(portName),getPortName(i)) then result:=i;
end;

procedure TMidiOut.openPort(portName:string);
VAR i,portNumber:integer;
   sender, receiver:snd_seq_addr_t;
VAR pinfo:Psnd_seq_port_info_t;
begin
  if ( Fconnected ) then exit;
  portNumber:=lookupName(portName);
  if portNumber<0 then exit;
  snd_seq_port_info_malloc( @pinfo );
  if ( portInfo(pinfo, SND_SEQ_PORT_CAP_WRITE or SND_SEQ_PORT_CAP_SUBS_WRITE, portNumber ) = 0 )  then exit;

    receiver.client := snd_seq_port_info_get_client( pinfo );
    receiver.port := snd_seq_port_info_get_port( pinfo );
    sender.client := snd_seq_client_id( data.seq );

    if ( data.vport < 0 ) then
    begin
      data.vport := snd_seq_create_simple_port( data.seq, @portName,
                                              SND_SEQ_PORT_CAP_READ or SND_SEQ_PORT_CAP_SUBS_READ,
                                              SND_SEQ_PORT_TYPE_MIDI_GENERIC or SND_SEQ_PORT_TYPE_APPLICATION );
      if ( data.vport < 0 ) then
      begin
  //      errorString_ = "MidiOutAlsa::openPort: ALSA error creating output port.";
  //      error( RtMidiError::DRIVER_ERROR, errorString_ );
        exit;
      end
    end;

    sender.port := data.vport;

    // Make subscription
    if ( snd_seq_port_subscribe_malloc( @data.subscription ) < 0 ) then
    begin
      snd_seq_port_subscribe_free( data.subscription );
  //    errorString_ = "MidiOutAlsa::openPort: error allocating port subscription.";
  //    error( RtMidiError::DRIVER_ERROR, errorString_ );
      exit;
    end;
    snd_seq_port_subscribe_set_sender( data.subscription, @sender );
    snd_seq_port_subscribe_set_dest( data.subscription, @receiver );
    snd_seq_port_subscribe_set_time_update( data.subscription, 1 );
    snd_seq_port_subscribe_set_time_real( data.subscription, 1 );
    if ( 0<>snd_seq_subscribe_port( data.seq, data.subscription ) ) then
    begin
      snd_seq_port_subscribe_free( data.subscription );
  //    errorString_ = "MidiOutAlsa::openPort: ALSA error making port connection.";
  //    error( RtMidiError::DRIVER_ERROR, errorString_ );
      exit;
    end;

  Fconnected := true;
end;

procedure TMidiOut.sendMessage(const message:TMidiOutBuffer; size:integer);
VAR ev:snd_seq_event_t;
    i,r:integer;
begin
  snd_seq_ev_clear( @ev );
  snd_seq_ev_set_source( @ev, data.vport );
  snd_seq_ev_set_subs( @ev );
  snd_seq_ev_set_direct( @ev );
  for i:=0 to size-1 do data.buffer[i] := message[i];
  r := snd_midi_event_encode( data.coder, @data.buffer, size, @ev );

  snd_seq_event_output_direct( data.seq, @ev );
  snd_seq_drain_output( data.seq );
end;

procedure TMidiOut.closePort;
begin
  Fconnected := false;
end;

constructor TMidiOut.Create;
VAR r:integer;
begin
  Data:=TAlsaMidiData.Create;
  Data.vport:=-1;
  data.portNum := -1;
  if snd_seq_open( @Data.seq, 'default', SND_SEQ_OPEN_DUPLEX, SND_SEQ_NONBLOCK ) < 0 then exit;
  r := snd_midi_event_new( 32, @data.coder );
  if ( r < 0 ) then
  begin
//    delete data;
//    errorString_ = "MidiOutAlsa::initialize: error initializing MIDI event parser!\n\n";
//    error( RtMidiError::DRIVER_ERROR, errorString_ );
    exit;
  end;
  snd_midi_event_init( data.coder );
end;

procedure TMidiIn.initialize;
begin
  Data:=TAlsaMidiData.Create;
  Data.vport:=-1;
  data.portNum := -1;
  if snd_seq_open( @Data.seq, 'default', SND_SEQ_OPEN_DUPLEX, SND_SEQ_NONBLOCK ) < 0 then exit;
end;

constructor TMidiIn.create;
begin
  initialize;
  OnMidiInput:=NIL;
end;

function TMidiIn.portInfo(pinfo: Psnd_seq_port_info_t; _type,portnumber:integer ): integer;
VAR cinfo:Psnd_seq_client_info_t;
client,count,atyp,caps:integer;
begin
 count:=0;
  snd_seq_client_info_malloc( @cinfo );

  snd_seq_client_info_set_client( cinfo, -1 );
  while ( snd_seq_query_next_client( data.seq, cinfo ) >= 0 ) do
  begin
    client := snd_seq_client_info_get_client( cinfo );
    if ( client = 0 ) then continue;
    // Reset query info
    snd_seq_port_info_set_client( pinfo, client );
    snd_seq_port_info_set_port( pinfo, -1 );
    while ( snd_seq_query_next_port( data.seq, pinfo ) >= 0 ) do
    begin
      atyp := snd_seq_port_info_get_type( pinfo );
      if ( ( ( atyp AND SND_SEQ_PORT_TYPE_MIDI_GENERIC ) = 0 ) AND
           ( ( atyp AND SND_SEQ_PORT_TYPE_SYNTH ) = 0 ) AND
           ( ( atyp AND SND_SEQ_PORT_TYPE_APPLICATION ) =0 ) ) then continue;

      caps := snd_seq_port_info_get_capability( pinfo );
      if ( ( caps AND _type ) <> _type ) then continue;
      if ( count = portNumber ) then begin result:=1; exit; end;
      inc(count);
    end;
  //}
  end;

  // If a negative portNumber was used, return the port count.
  if ( portNumber < 0 ) then result:=count
  else result:=0;
end;

function TMidiIn.getPortName(portNumber:integer):string;
VAR
  cinfo: Psnd_seq_client_info_t ;
  pinfo: Psnd_seq_port_info_t;
  stringName:string;
  cnum:integer;

begin
  snd_seq_client_info_malloc( @cinfo );
  snd_seq_port_info_malloc( @pinfo );
  if portInfo( pinfo, SND_SEQ_PORT_CAP_READ or SND_SEQ_PORT_CAP_SUBS_READ, portNumber ) > 0 then
  begin
    cnum := snd_seq_port_info_get_client( pinfo );
    snd_seq_get_any_client_info( data.seq, cnum, cinfo );
    //client:=snd_seq_port_info_get_client( pinfo );
    //port:=snd_seq_port_info_get_port( pinfo );
    stringName:=snd_seq_client_info_get_name( cinfo );
    result:=stringName;
    exit;
  end;
  result:='NOP';
end;

function TMidiIn.lookupName(portName: string): integer;
VAR i:integer;
begin
  result:=-1;
  for i:=0 to getPortCount-1 do
    if 1=Pos(Uppercase(portName),getPortName(i)) then result:=i;
end;

procedure TMidiIn.openPort(portName:string);
VAR i,portNumber:integer;
   sender, receiver:snd_seq_addr_t;
VAR src_pinfo,pinfo:Psnd_seq_port_info_t;
begin
  if ( Fconnected ) then exit;
  portNumber:=lookupName(portName);
  if portNumber<0 then exit;
  snd_seq_port_info_malloc( @src_pinfo );
  if ( portInfo(src_pinfo, SND_SEQ_PORT_CAP_READ or SND_SEQ_PORT_CAP_SUBS_READ, portNumber ) = 0 )  then exit;

    sender.client := snd_seq_port_info_get_client( src_pinfo );
    sender.port := snd_seq_port_info_get_port( src_pinfo );
    receiver.client := snd_seq_client_id( data.seq );

    snd_seq_port_info_malloc( @pinfo );

    if ( data.vport < 0 ) then
    begin
      snd_seq_port_info_set_client( pinfo, 0 );
       snd_seq_port_info_set_port( pinfo, 0 );
       snd_seq_port_info_set_capability( pinfo,
                                         SND_SEQ_PORT_CAP_WRITE or
                                         SND_SEQ_PORT_CAP_SUBS_WRITE );
       snd_seq_port_info_set_type( pinfo,
                                   SND_SEQ_PORT_TYPE_MIDI_GENERIC or
                                   SND_SEQ_PORT_TYPE_APPLICATION );
       snd_seq_port_info_set_midi_channels(pinfo, 16);


     // data.vport := snd_seq_create_simple_port( data.seq, @portName,
       //                                       SND_SEQ_PORT_CAP_READ or SND_SEQ_PORT_CAP_SUBS_READ,
         //                                     SND_SEQ_PORT_TYPE_MIDI_GENERIC or SND_SEQ_PORT_TYPE_APPLICATION );
         snd_seq_port_info_set_name( pinfo,  PChar(portName) );
         data.vport := snd_seq_create_port( data.seq, pinfo );
      if ( data.vport < 0 ) then
      begin
  //      errorString_ = "MidiOutAlsa::openPort: ALSA error creating output port.";
  //      error( RtMidiError::DRIVER_ERROR, errorString_ );
        exit;
      end
    end;

    receiver.port := data.vport;

    // Make subscription
    if ( snd_seq_port_subscribe_malloc( @data.subscription ) < 0 ) then
    begin
      snd_seq_port_subscribe_free( data.subscription );
  //    errorString_ = "MidiOutAlsa::openPort: error allocating port subscription.";
  //    error( RtMidiError::DRIVER_ERROR, errorString_ );
      exit;
    end;
    snd_seq_port_subscribe_set_sender( data.subscription, @sender );
    snd_seq_port_subscribe_set_dest( data.subscription, @receiver );
//    snd_seq_port_subscribe_set_time_update( data.subscription, 1 );
//    snd_seq_port_subscribe_set_time_real( data.subscription, 1 );
    if ( 0<>snd_seq_subscribe_port( data.seq, data.subscription ) ) then
    begin
      snd_seq_port_subscribe_free( data.subscription );
  //    errorString_ = "MidiOutAlsa::openPort: ALSA error making port connection.";
  //    error( RtMidiError::DRIVER_ERROR, errorString_ );
      exit;
    end;
  FThread:=TMidiInThread.Create(self);
  Fconnected := true;
end;

procedure TMidiIn.InputThread;
VAR r:integer;
    ev:psnd_seq_event_t;
VAR nBytes:integer;
begin
  ThreadTerminated:=false;
  r := snd_midi_event_new( 32, @data.coder );
  if ( r < 0 ) then exit;
  snd_midi_event_init( Data.coder );
  snd_midi_event_no_status( Data.coder, 1 ); // suppress running status messages
  while not ThreadTerminated do
  begin
    r:= snd_seq_event_input( Data.seq, @ev );
    if ( r <= 0 ) then
       continue;
    nBytes := snd_midi_event_decode( Data.coder, @data.buffer, 32, ev );
    if ( nBytes > 0 ) and assigned(OnMidiInput) then
      OnMidiInput(data.buffer,nBytes);
    snd_seq_free_event(ev);
  end;
end;

function TMidiIn.getPortCount: integer;
VAR pinfo:Psnd_seq_port_info_t;
begin
  snd_seq_port_info_malloc( @pinfo );
  result:=portInfo( pinfo, SND_SEQ_PORT_CAP_READ or SND_SEQ_PORT_CAP_SUBS_READ, -1 );
end;

procedure TMidiIn.closePort;
begin
  if FConnected then
  begin
    snd_seq_unsubscribe_port( data.seq, data.subscription );
    snd_seq_port_subscribe_free( data.subscription );
    data.subscription :=NIL;
  end;
  Fconnected := false;
  // stop the thread
end;


procedure TMidiInThread.Execute;
begin
  FMidiIn.InputThread;
end;

constructor TMidiInThread.Create(MidiIn:TMidiIn);
begin
  FMidiIn:=MidiIn;
  inherited Create(false);
end;


end.

