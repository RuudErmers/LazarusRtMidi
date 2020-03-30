program project1;

{$mode delphi}

uses
  cthreads,
  Interfaces, // this includes the LCL widgetset
  Forms, Unit1, URtMidi
  { you can add units after this };

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Initialize;
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.

