----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 15.12.2021
-- Design Name: 
-- Module Name: CACFAR - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;


use std.textio.all;

entity oscfar is
	generic(
        -- Data window size
		DATA_WINDOW : natural := 64;
        -- CACFAR window size width
		OSCFAR_WINDOW_W : natural := 4;
        -- data width
		DATA_W : natural := 16
	);
	port(
        -- clock
		clk    : in  std_logic;
        -- active-low reset
		rst    : in  std_logic;
		-- cacfar window size, valid range is [5; DATA_WINDOW]
		i_oscfar_window : in std_logic_vector(OSCFAR_WINDOW_W - 1 downto 0);
		-- leading/lagging windows size 
		i_m : in std_logic_vector(OSCFAR_WINDOW_W - 1 downto 0);
		-- cacfar/leading/lagging window sizes write enable
		i_oscfar_window_we : in std_logic;
        -- data write enable
		we     : in  std_logic;
        -- input data
		i_data : in  std_logic_vector(DATA_W - 1 downto 0);
        -- output data
		o_data : out std_logic_vector(DATA_W - 1 downto 0);
		o_tag  : out std_logic
	);
end oscfar;

architecture Behavioral of oscfar is

    -- Define the maximum M value for given DATA_WINDOW
	constant M_MAX : natural := (DATA_WINDOW - 1)/2 - 1;
    -- Define the maximum G value for given DATA_WINDOW
	constant G_MAX : natural := (DATA_WINDOW - 2*M_MAX - 1)/2;
	-- 
	constant SORTER_ADDR_WIDTH : natural := integer(ceil(log2(real(2*M_MAX))));
    
    -- FSM signals
	type states is (Idle, ReadCut, LoadSorter, Sorting, OscfarThreshold, OscfarDecision);
	signal state : states;

	-- RAM signals
	constant ADDR_WIDTH : positive := positive(ceil(log2(real(DATA_WINDOW ))));
	type ram is array (0 to 2**ADDR_WIDTH - 1) of std_logic_vector(DATA_W - 1 downto 0);
	signal cells        : ram      := (others => (others => '0'));
	signal w_addr       : integer range 0 to 2**ADDR_WIDTH - 1; -- write address
	signal cut_data    : std_logic_vector(DATA_W - 1 downto 0); -- read data port 1
	signal ram_filled   : boolean;

	
	-- Internal signals
	constant ALPHA_WIDTH : natural := natural(ceil(log2(real(5)))) + 1;
	signal read_cut_ctr  : integer range 0 to 1; -- Pointer within each window
	signal window_ptr    : integer range -(M_MAX + G_MAX + 2) to M_MAX + G_MAX + 2; -- Pointer within each window
	signal cut_addr      : unsigned(ADDR_WIDTH - 1 downto 0); -- Pointer to the current cell under test    
	signal cut_value     : signed(DATA_W - 1 downto 0); -- Latch the value of the current cell under test
	signal threshold     : signed(DATA_W + ALPHA_WIDTH - 1 downto 0);
	signal cfar_window   : natural range 0 to DATA_WINDOW;
	signal m : natural range 1 to M_MAX;
	signal g : natural range 1 to G_MAX;
	signal sorter_data_ld : std_logic;
	signal sorter_addr : unsigned(SORTER_ADDR_WIDTH - 1 downto 0);
	signal sorter_data_i : std_logic_vector(DATA_W - 1 downto 0);
	signal sorter_start : std_logic;
	signal sorter_done : std_logic;
	signal sorter_data_o : std_logic_vector(DATA_W - 1 downto 0);

begin
	
	-- latch cfar window size
	process(clk)
	begin
		if rising_edge(clk) then
			if rst = '0' then
				cfar_window <= 12; -- some default value
				m <= 4; -- some default value
			elsif i_oscfar_window_we = '1' then
				cfar_window <= to_integer(unsigned(i_oscfar_window));
				m <= to_integer(unsigned(i_m));
			end if;
		end if;
	end process;
		
    -- finding g value
	g <= (cfar_window - 2*m - 1) / 2;
	
	-- ram process
	ram_m : process(clk)
	begin
		if rising_edge(clk) then
			-- write port
			if we = '1' then
				cells(w_addr) <= i_data;
			end if;

			-- read ports
			cut_data  <= cells(to_integer(cut_addr)); 
		end if;
	end process;

	-- finite state machine process
	fsm_p : process(clk)
	begin
		if rising_edge(clk) then
			if rst = '0' then
				ram_filled   <= false;
				w_addr       <= 0;
				cut_addr     <= (others => '0');
				window_ptr   <= 2;
				read_cut_ctr <= 0;
				cut_value    <= (others => '0');
				threshold    <= (others => '0');
				o_data       <= (others => '0');
				o_tag        <= '0';
				sorter_addr <= (others => '0');
			else
				case state is
					when Idle =>
						if we = '1' then
							
							-- Update write address port
							if w_addr = ram'HIGH then
								w_addr <= ram'LOW;
							else
								w_addr <= w_addr + 1;
							end if;

							-- Update cut address
							cut_addr  <= to_unsigned(w_addr - cfar_window/2, ADDR_WIDTH);

							-- State of the ram
							if w_addr = ram'HIGH then
								ram_filled <= true;
							end if;

							-- Move to next state
							if w_addr >= cfar_window or ram_filled then
								state <= ReadCut;
							end if;
						end if;
						window_ptr <= -(g + m);
					when ReadCut =>
						if read_cut_ctr = 0 then -- wait for the cycle that ram needs.
							read_cut_ctr <= read_cut_ctr + 1;
						elsif read_cut_ctr = 1 then -- Read cut value and move to next state
							read_cut_ctr <= 0;
							cut_value    <= signed(cut_data);
							state <= LoadSorter;
						end if;
						sorter_addr <= (others => '0');
					when LoadSorter =>
						if window_ptr = g + m then
							sorter_start <= '1';
							state <= Sorting;
						elsif window_ptr = -g then
							window_ptr <= window_ptr + 2 * g + 1;
						else
							window_ptr <= window_ptr + 1;
						end if;
						sorter_addr <= sorter_addr + 1;
					when Sorting =>
						sorter_start <= '0';
						if sorter_done = '1' then 
							state <= OscfarThreshold;
						end if;
						sorter_addr <= to_unsigned(m, sorter_addr'length);
					when OscfarThreshold => -- Threshold
						threshold <= to_signed(5, ALPHA_WIDTH) * signed(sorter_data_o);
						-- Next state
						state     <= OscfarDecision;

					when OscfarDecision => -- CUT cfar_decision                    
						if resize(cut_value, threshold'LENGTH) >= threshold then
							o_data <= std_logic_vector(cut_value - 1);
							o_tag <= '1';
						else
							o_data <= std_logic_vector(cut_value);
							o_tag <= '0';
						end if;

						-- Next state
						state <= Idle;
				end case;
			end if;
		end if;
	end process;
	
	sorter_data_ld <= '1' when state = LoadSorter else '0';
	sorter_data_i <= cut_data;
	
	merge_sort_inst : entity work.merge_sort
		generic map(
			DATA_WIDTH => DATA_W,
			BUF_SIZE   => 2*M_MAX,
			ADDR_WIDTH => SORTER_ADDR_WIDTH
		)
		port map(
			i_clk         => clk,
			i_reset       => rst,
			i_data_valid  => sorter_data_ld,
			i_data_addr   => std_logic_vector(sorter_addr),
			i_data        => sorter_data_i,
			i_sort_length => std_logic_vector(to_unsigned(2*m, SORTER_ADDR_WIDTH + 1)),
			i_start_sort  => sorter_start,
			o_sort_done   => sorter_done,
			o_data        => sorter_data_o
		);
	

end Behavioral;
