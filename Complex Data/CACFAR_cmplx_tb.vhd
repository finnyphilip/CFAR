library ieee;
use     ieee.std_logic_1164.all;
use		ieee.std_logic_textio.all;

library std;
use 	std.textio.all;

entity CACFAR_cmplx_tb is

end CACFAR_cmplx_tb;

architecture Behavioral of CACFAR_cmplx_tb is

	constant CACFAR_DATA_WINDOW : natural := 64;
	constant CACFAR_DATA_WIDTH : natural := 39;

    -- Clock and reset signals
    constant Tclk           :   time        :=  1 us;
    signal stop_clk         :   boolean     :=  false;

    -- Stimuli signals
    constant latency        :   positive    :=  13;    -- Latency for each cell
    signal stop_stimuli     :   boolean     :=  false;
    signal periods          :   integer range 0 to 64; 
    signal ctr              :   integer range 0 to 80;            
    
    -- DUT signals
    signal clk              :   std_logic;
    signal rst              :   std_logic;
    signal we               :   std_logic;
    signal i_data           :   std_logic_vector(CACFAR_DATA_WIDTH - 1 downto 0);
    signal o_data           :   std_logic_vector(23 downto 0);
    signal cfar_window : std_logic_vector(9 downto 0);
    signal cfar_window_we : std_logic;
    signal en : std_logic := '0';

    
begin

	en <= '1' after 30 us;
    -- DUT instantiation
    DUT :   entity work.CACFAR_cmplx
    	generic map(
    		DATA_WINDOW => CACFAR_DATA_WINDOW
    	)
    	port map(
    		clk              => clk,
    		rst              => rst,
    		i_cfar_window    => cfar_window,
    		i_cfar_window_we => cfar_window_we,
    		we               => we,
    		i_data           => i_data,
    		o_data           => o_data
    	);
    	
    -- Read stimuli from matlab 
    from_txt	:	process
		file		i_file		:	text open READ_MODE is "D:/work/cacfar/matlab/stimuli.txt";
		variable	file_line	:	line;
		variable	stimuli	    :	std_logic_vector(15 downto 0);
	begin
		wait until en = '1';
	    wait until rising_edge(clk);	    
		while not endfile(i_file) loop	 
		    readline(i_file,file_line);
			read(file_line,stimuli);
			i_data	<=	stimuli & "000" & X"00000";
			we <= '1';
			wait for Tclk;
			i_data	<=	(others => '0');
			wait for Tclk;
			we <= '0';
			wait for Tclk * latency;
		end loop;
		file_close(i_file);
		wait;
	end process;

    -- Clock process
    clk_p   :   process
    begin
        while not stop_clk loop
            clk     <=  '1';
            wait for Tclk/2;
            clk     <=  '0';
            wait for Tclk/2;
        end loop;
        wait;
    end process;

    -- Reset process
    rst_p   :   process 
    begin
        rst     <=  '0';
        wait for 25 us;
        rst     <=  '1';
        wait;
    end process;

     

end Behavioral;