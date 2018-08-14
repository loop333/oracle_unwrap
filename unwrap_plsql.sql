declare
 v_text  varchar2(4000);
 tmp     blob;
 tmp2    blob;
 tmp3    blob;
 b64_len integer;
 str     varchar2(1000);
 charmap raw(256) := hextoraw(replace(
  '3D 65 85 B3 18 DB E2 87 F1 52 AB 63 4B B5 A0 5F' ||
  '7D 68 7B 9B 24 C2 28 67 8A DE A4 26 1E 03 EB 17' ||
  '6F 34 3E 7A 3F D2 A9 6A 0F E9 35 56 1F B1 4D 10' ||
  '78 D9 75 F6 BC 41 04 81 61 06 F9 AD D6 D5 29 7E' ||
  '86 9E 79 E5 05 BA 84 CC 6E 27 8E B0 5D A8 F3 9F' ||
  'D0 A2 71 B8 58 DD 2C 38 99 4C 48 07 55 E4 53 8C' ||
  '46 B6 2D A5 AF 32 22 40 DC 50 C3 A1 25 8B 9C 16' ||
  '60 5C CF FD 0C 98 1C D4 37 6D 3C 3A 30 E8 6C 31' ||
  '47 F5 33 DA 43 C8 E3 5E 19 94 EC E6 A3 95 14 E0' ||
  '9D 64 FA 59 15 C5 2F CA BB 0B DF F2 97 BF 0A 76' ||
  'B4 49 44 5A 1D F0 00 96 21 80 7F 1A 82 39 4F C1' ||
  'A7 D7 0D D1 D8 FF 13 93 70 EE 5B EF BE 09 B9 77' ||
  '72 E7 B2 54 B7 2A C7 73 90 66 20 0E 51 ED F8 7C' ||
  '8F 2E F4 12 C6 2B 83 CD AC CB 3B C4 4E C0 69 36' ||
  '62 02 AE 88 FC AA 42 08 A6 45 57 D3 9A BD E1 23' ||
  '8D 92 4A 11 89 74 6B 91 FB FE C9 01 EA 1B F7 CE' ,' ',''));

 v_offset      integer;
 v_buffer_size binary_integer := 4800;
 v_buffer_raw  raw(4800);

 t_out      blob;
 t_tmp      blob;
 t_buffer   raw(1);
 t_hdl      binary_integer;
 t_s1       pls_integer; -- s1 part of adler32 checksum
 t_last_chr pls_integer;
begin
 dbms_output.enable(null);

 dbms_lob.createtemporary(tmp, true);
 dbms_lob.createtemporary(tmp2, true);
 dbms_lob.createtemporary(tmp3, true);
 --  type, owner and object name (package, package body, procedure or function) to unwrap 
 for c in (select line, text from dba_source where type = 'PACKAGE BODY' and owner = 'OWNER' and name = 'PACKAGE BODY NAME' order by line) loop
  if c.line = 1 then
   b64_len := to_number(regexp_substr(regexp_substr(c.text, '^[0-9a-f]+ [0-9a-f]+$',1,1,'m'), '[0-9a-f]+', 1, 2),'XXXXXXXXXX');
   dbms_lob.append(tmp, utl_raw.cast_to_raw(replace(substr(c.text, regexp_instr(c.text,'^[0-9a-f]+ [0-9a-f]+$',1,1,1,'m')), chr(10), '')));
  else
   dbms_lob.append(tmp, utl_raw.cast_to_raw(replace(c.text,chr(10), '')));
  end if;
 end loop;  
 -- dbms_output.put_line(dbms_lob.getlength(tmp));

 -- dbms_lob.trim(tmp,b64_len);

 -- base64 unpack
 -- tmp := utl_encode.base64_decode(tmp);

 v_offset := 1;
 for i in 1 .. ceil(dbms_lob.getlength(tmp)/v_buffer_size) loop
  dbms_lob.read(tmp,v_buffer_size,v_offset,v_buffer_raw);
  v_buffer_raw := utl_encode.base64_decode(v_buffer_raw);
  dbms_lob.writeappend(tmp2, utl_raw.length(v_buffer_raw), v_buffer_raw);
  v_offset := v_offset + v_buffer_size;
 end loop;
 
 -- remove first 20 bytes
 dbms_lob.copy(tmp3, tmp2, dbms_lob.getlength(tmp)-20, 1, 21);

 -- recode by table charmap
 for i in 1 .. dbms_lob.getlength(tmp3) loop
  dbms_lob.write(tmp3, 1, i, utl_raw.substr(charmap, utl_raw.cast_to_binary_integer(dbms_lob.substr(tmp3, 1, i))+1, 1));
 end loop;

-- zlib unpack
 dbms_lob.createtemporary(t_out, true);
 dbms_lob.createtemporary(t_tmp, true);
 t_tmp := hextoraw('1F8B0800000000000003'); -- gzip header
 dbms_lob.copy(t_tmp, tmp3, dbms_lob.getlength(tmp3)-2-4, 11, 3);
 dbms_lob.append(t_tmp, hextoraw('0000000000000000')); -- add a fake trailer
 t_hdl := utl_compress.lz_uncompress_open(t_tmp);
 t_s1 := 1;
 loop
  begin
   utl_compress.lz_uncompress_extract(t_hdl, t_buffer);
  exception
   when others then exit;
  end;
  dbms_lob.append(t_out, t_buffer);
  t_s1 := mod(t_s1 + to_number(rawtohex(t_buffer), 'xx'), 65521);
 end loop;

 t_last_chr := to_number(dbms_lob.substr(tmp3, 2, dbms_lob.getlength(tmp3)-1), '0XXX') - t_s1;
 if t_last_chr < 0 then
  t_last_chr := t_last_chr + 65521;
 end if;
 dbms_lob.append(t_out, hextoraw(to_char(t_last_chr, 'fm0X')));
 if utl_compress.isopen(t_hdl) then
  utl_compress.lz_uncompress_close(t_hdl);
 end if;

 str := '';
 for i in 1 .. dbms_lob.getlength(t_out) loop
  if utl_raw.cast_to_varchar2(dbms_lob.substr(t_out, 1, i)) = chr(10) then
   dbms_output.put_line(str);
   str := '';
  else
   str := str || utl_raw.cast_to_varchar2(dbms_lob.substr(t_out, 1, i));
  end if;
 end loop;
 dbms_output.put_line(str);

 dbms_lob.freetemporary(t_tmp);
 dbms_lob.freetemporary(t_out);

 dbms_lob.freetemporary(tmp3);
 dbms_lob.freetemporary(tmp2);
 dbms_lob.freetemporary(tmp);
end;
