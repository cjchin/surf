-------------------------------------------------------------------------------
-- Title         : SSI Lib, Simulation Link
-- Project       : General Purpose Core
-------------------------------------------------------------------------------
-- File          : SimLink.vhd
-- Author        : Ryan Herbst, rherbst@slac.stanford.edu
-- Created       : 04/18/2014
-------------------------------------------------------------------------------
-- Description:
-------------------------------------------------------------------------------
-- Copyright (c) 2014 by Ryan Herbst. All rights reserved.
-------------------------------------------------------------------------------
-- Modification history:
-- 04/18/2014: created.
-------------------------------------------------------------------------------

LIBRARY ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;
use work.StdRtlPkg.all;
use work.AxiStreamPkg.all;

entity AxiStreamSimLink is 
   generic (
      TPD_G            : time                   := 1 ns;
      TDATA_BYTES_G    : integer range 2 to 4   := 2; -- 2 or 4
      EOFE_TUSER_BIT_G : integer range 0 to 127 := 0
   );
   port ( 

      -- Slave, non-interleaved, 32-bit or 16-bit interface, tkeep not supported
      sAxiClk          : in  sl;
      sAxiRst          : in  sl;
      sAxiStreamMaster : in  AxiStreamMasterType;
      sAxiStreamSlave  : out AxiStreamSlaveType;

      -- Master, non-interleaved, 32-bit or 16-bit interface, tkeep not supported
      mAxiClk          : in  sl;
      mAxiRst          : in  sl;
      mAxiStreamMaster : out AxiStreamMasterType;
      mAxiStreamSlave  : in  AxiStreamSlaveType
   );
end AxiStreamSimLink;

-- Define architecture
architecture AxiStreamSimLink of AxiStreamSimLink is

   -- Local Signals
   signal ibValid  : sl;
   signal ibDest   : slv(3 downto 0);
   signal ibEof    : sl;
   signal ibEofe   : sl;
   signal ibData   : slv(31 downto 0);
   signal ibPos    : sl;
   signal obValid  : sl;
   signal obSize   : sl;
   signal obDest   : slv(3 downto 0);
   signal obEof    : sl;
   signal obData   : slv(31 downto 0);

   type RegType is record
      master : AxiStreamMasterType;
      ready  : sl;
      pos    : sl;
   end record RegType;

   constant REG_INIT_C : RegType := (
      master => AXI_STREAM_MASTER_INIT_C,
      ready  => '0',
      pos    => '0'
   );

   signal r   : RegType := REG_INIT_C;
   signal rin : RegType;

begin

   ------------------------------------
   -- Inbound
   ------------------------------------

   sAxiStreamSlave.tReady <= '1';

   process (sAxiClk) begin
      if rising_edge(sAxiClk) then
         if sAxiRst = '1' then
            ibValid <= '0'           after TPD_G;
            ibData  <= (others=>'0') after TPD_G;
            ibDest  <= (others=>'0') after TPD_G;
            ibEof   <= '0'           after TPD_G;
            ibEofe  <= '0'           after TPD_G;
            ibPos   <= '0'           after TPD_G;
         else

            if sAxiStreamMaster.tValid = '1' then
               if TDATA_BYTES_G = 4 then
                  ibValid <= sAxiStreamMaster.tValid                                             after TPD_G;
                  ibData  <= sAxiStreamMaster.tData(31 downto 0)                                 after TPD_G;
                  ibDest  <= sAxiStreamMaster.tDest(3 downto 0)                                  after TPD_G;
                  ibEof   <= sAxiStreamMaster.tLast                                              after TPD_G;
                  ibEofe  <= sAxiStreamMaster.tLast and sAxiStreamMaster.tUser(EOFE_TUSER_BIT_G) after TPD_G;  -- Fix this

               elsif ibPos = '0' then
                  ibPos               <= '1'                                 after TPD_G;
                  ibValid             <= '0'                                 after TPD_G;
                  ibData(15 downto 0) <= sAxiStreamMaster.tData(15 downto 0) after TPD_G;

                  assert ( sAxiStreamMaster.tLast = '0' )
                     report "Invalid tLast position in slave simLink" severity failure;

               else
                  ibPos                <= '0'                                                                 after TPD_G;
                  ibValid              <= '1'                                                                 after TPD_G;
                  ibData(31 downto 16) <= sAxiStreamMaster.tData(15 downto 0)                                 after TPD_G;
                  ibDest               <= sAxiStreamMaster.tDest(3 downto 0)                                  after TPD_G;
                  ibEof                <= sAxiStreamMaster.tLast                                              after TPD_G;
                  ibEofe               <= sAxiStreamMaster.tLast and sAxiStreamMaster.tUser(EOFE_TUSER_BIT_G) after TPD_G; -- Fix this
               end if;
            else
               ibValid <= '1' after TPD_G;
            end if;
         end if;
      end if;
   end process;

   U_SimLinkIb: entity work.AxiStreamSimLinkIb
      port map (
         ibClk   => sAxiClk,
         ibReset => sAxiRst,
         ibValid => ibValid,
         ibDest  => ibDest,
         ibEof   => ibEof,
         ibEofe  => ibEofe,
         ibData  => ibData
      );

   assert ( sAxiStreamMaster.tDest < 4 )
      report "Invalid tDest value in slave simLink" severity failure;

   assert ( (TDATA_BYTES_G = 2 and sAxiStreamMaster.tKeep(3 downto 0) = "0011") or 
            (TDATA_BYTES_G = 4 and sAxiStreamMaster.tKeep(3 downto 0) = "1111") )
      report "Invalid tKeep value in slave simLink" severity failure;


   ------------------------------------
   -- Outbound
   ------------------------------------

   comb : process (mAxiRst, r, mAxiStreamSlave, obValid, obSize, obDest, obEof, obData ) is
      variable v        : RegType;
   begin
      v := r;

      v.master.tValid := '0';
      v.ready         := '0';

      -- Advance
      if mAxiStreamSlave.tReady = '1' or r.master.tValid = '0' then

         -- 32-bit interface
         if TDATA_BYTES_G = 4 then
            v.master.tValid             := obValid;
            v.master.tData(31 downto 0) := obData;
            v.master.tStrb(3  downto 0) := "1111";
            v.master.tKeep(3  downto 0) := "1111";
            v.master.tLast              := obEof;
            v.master.tDest(3  downto 0) := obDest;
            v.ready                     := '1';

         -- 16bit interface, low position
         elsif r.pos = '0' then
            v.master.tValid             := obValid;
            v.master.tData(15 downto 0) := obData(15 downto 0);
            v.master.tStrb(3 downto 0)  := "0011";
            v.master.tKeep(3 downto 0)  := "0011";
            v.master.tLast              := '0';
            v.master.tDest(3 downto 0)  := obDest;
            v.ready                     := '0';

         -- 16bit interface, high position
         else 
            v.master.tValid             := obValid;
            v.master.tData(15 downto 0) := obData(31 downto 16);
            v.master.tStrb(3 downto 0)  := "0011";
            v.master.tKeep(3 downto 0)  := "0011";
            v.master.tLast              := obEof;
            v.master.tDest(3 downto 0)  := obDest;
            v.ready                     := '1';
         end if;
      end if;

      if (mAxiRst = '1') then
         v := REG_INIT_C;
      end if;

      rin <= v;

      mAxiStreamMaster <= r.master;

   end process comb;

   seq : process (mAxiClk) is
   begin
      if (rising_edge(mAxiClk)) then
         r <= rin after TPD_G;
      end if;
   end process seq;

   U_SimLinkOb: entity work.AxiStreamSimLinkOb
      port map (
         obClk   => mAxiClk,
         obReset => mAxiRst,
         obValid => obValid,
         obDest  => obDest,
         obEof   => obEof,
         obData  => obData,
         obReady => r.ready
      );

end AxiStreamSimLink;

