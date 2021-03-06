// vim: set foldmethod=syntax foldlevel=1 expandtab ts=4 sts=4 expandtab sw=4 filetype=d :
/* cpu.d
* Emulation code for the MOS5602 CPU.
* Copyright (c) 2015 dNES Team.
* License: GPL 3.0
*/

module cpu.mos6502;
import cpu.statusregister;
import cpu.exceptions;
import console;
import memory;

class MOS6502
{
    public this()
    {
        _status = new StatusRegister;
        _registers = new Registers;

        _pageBoundaryWasCrossed = false;
    }

    // From http://wiki.nesdev.com/w/index.php/CPU_power_up_state
    public void powerOn()
    {
        _status.asWord = 0x34;
        _registers.a = _registers.x = _registers.y = 0;
        _registers.sp = 0xFD;

        if (Console.ram is null)
        {
            // Ram will only be null if a prior emulation has ended or if we are
            // unit-testing. Normally, console will allocate this on program
            // start.
            Console.ram = new RAM;
        }
        _registers.pc = 0xC000;
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();

        assert(cpu._status.asWord == 0x34);
        assert(cpu._registers.a == 0);
        assert(cpu._registers.x == 0);
        assert(cpu._registers.y == 0);
        assert(cpu._registers.pc == 0xC000);

        // Do not test the Console.ram constructor here, it should be tested
        // in ram.d
    }

    // From http://wiki.nesdev.com/w/index.php/CPU_power_up_state
    // After reset
    //    A, X, Y were not affected
    //    S was decremented by 3 (but nothing was written to the stack)
    //    The I (IRQ disable) flag was set to true (_status ORed with $04)
    //    The internal memory was unchanged
    //    APU mode in $4017 was unchanged
    //    APU was silenced ($4015 = 0)
    private void reset()
    {
        _registers.sp -= 0x03;
        _status.asWord = _status.asWord | 0x04;
        // TODO: Console.MemoryMapper.Write(0x4015, 0);
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();

        cpu._status.asWord = 0x01;
        cpu._registers.a = cpu._registers.x = cpu._registers.y = 55;
        cpu._registers.sp = 0xF4;
        cpu._registers.pc= 0xF000;
        cpu.reset();

        assert(cpu._registers.sp == (0xF4 - 0x03));
        assert(cpu._status.asWord == (0x21 | 0x04)); // bit 6 (0x20) is always on
    }

    private ubyte fetch()
    {
        return Console.ram.read(_registers.pc++);
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();

        // Case 1: pc register properly incremented
        auto instruction = cpu.fetch();
        assert(cpu._registers.pc == 0xC001);

        // Case 2: Instruction is properly read
        Console.ram.write(cpu._registers.pc, 0xFF);  // TODO: Find a way to replace with a MockRam class
        instruction = cpu.fetch();
        assert(cpu._registers.pc == 0xC002);
        assert(instruction == 0xFF);
    }

    private void delegate(ubyte) decode(ubyte opcode)
    {
        switch (opcode)
        {
        // JMP
        case 0x4C:
        case 0x6C:
            return &JMP;
        // ADC
        case 0x69:
        case 0x65:
        case 0x75:
        case 0x6D:
        case 0x7D:
        case 0x79:
        case 0x61:
        case 0x71:
            return &ADC;
        case 0x78:
            return &CLI;
        case 0x88:
            return &DEY;
        case 0xCA:
            return &DEX;
        case 0xEA:
            return &NOP;
        default:
            throw new InvalidOpcodeException(opcode);
        }
    }
    // TODO: Write unit test before writing implementation (TDD)
    unittest
    {
        import std.file, std.stdio;

        // Load a test ROM
        auto ROMBytes = cast(ubyte[])read("libdnes/specs/nestest.nes");
        auto cpu     = new MOS6502;
        cpu.powerOn();

        {
            ushort address = 0xC000;
            for (uint i = 0x10; i < ROMBytes.length; ++i) {
                Console.ram.write(address, ROMBytes[i]);
                ++address;
            }
        }

        auto resultFunc = cpu.decode(cpu.fetch());
        void delegate(ubyte) expectedFunc = &(cpu.JMP);
        assert(resultFunc == expectedFunc);
    }

    //perform another cpu cycle of emulation
    private void cycle()
    {
        //Priority: Reset > NMI > IRQ
        if (_rst)
        {
            handleReset();
        }
        if (_nmi)
        {
            handleNmi();
        }
        if (_irq)
        {
            handleIrq();
        }
        //Fetch
        ubyte opcode = fetch();
        //Decode
        auto instructionFunction = decode(opcode);
        //Execute
        instructionFunction(opcode);
    }
    unittest
    {
        auto cpu = new MOS6502;
        auto savedCycles = cpu._cycleCount;
        auto ram = Console.ram;
        //Check if RST is handled
        cpu.setReset();
        //set reset vector memory

        ram.write16(cpu._resetAddress, 0x00); //write address 00 to reset vector
        ram.write(0x00, 0xEA); //write  NOP instruction to address 0x00
        cpu.cycle();
        assert(cpu._rst == false);

        assert(cpu._cycleCount == savedCycles + 7 + 2); //2 cycles for NOP
    }

    private void handleReset()
    {
        auto resetVectorAddress = Console.ram.read16(_resetAddress);
        _registers.pc = resetVectorAddress;
        _rst = false;
        _cycleCount += 7;
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        auto ram = Console.ram;
        auto savedCycles = cpu._cycleCount;
        ram.write16(cpu._resetAddress, 0xFC10); //write interrupt handler address
        cpu._rst = true;
        cpu.handleReset();
        assert(cpu._cycleCount == savedCycles + 7);
        assert(cpu._registers.pc == 0xFC10);
        assert(cpu._rst == false);
    }

    private void handleNmi()
    {
        pushStack(cast(ubyte)(_registers.pc >> 8)); //write PC high byte to stack
        pushStack(cast(ubyte)(_registers.pc));
        pushStack(_status.asWord);
        auto _nmiVectorAddress = Console.ram.read16(_nmiAddress);
        _registers.pc = _nmiVectorAddress;
        _nmi = false;
        _cycleCount += 7;
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        auto ram = Console.ram;
        auto savedCycles = cpu._cycleCount;
        auto savedPC = cpu._registers.pc;
        auto savedStatus = cpu._status.asWord;
        ram.write16(cpu._nmiAddress, 0x1D42); //write interrupt handler address
        cpu.handleNmi();
        assert(cpu.popStack() == savedStatus); //check _status _registers
        ushort previousPC = cpu.popStack() | (cpu.popStack() << 8); //verify pc write
        assert(cpu._cycleCount == savedCycles + 7);
        assert(cpu._registers.pc == 0x1D42);
        assert(previousPC == savedPC);

    }

    private void handleIrq()
    {
        if(_status.i)
            return; //don't do anything if interrupt disable is set

        pushStack(cast(ubyte)(_registers.pc >> 8)); //write PC high byte to stack
        pushStack(cast(ubyte)(_registers.pc));
        pushStack(_status.asWord);
        auto _irqVectorAddress = Console.ram.read16(_irqAddress);
        _registers.pc = _irqVectorAddress;
        _cycleCount +=7;
    }
    unittest
    {
        //case 1 : interrupt disable bit is not set
        auto cpu = new MOS6502;
        cpu.powerOn();
        cpu._status.i = false;
        auto ram = Console.ram;
        auto savedCycles = cpu._cycleCount;
        auto savedPC = cpu._registers.pc;
        auto savedStatus = cpu._status.asWord;
        ram.write16(cpu._irqAddress, 0xC296); //write interrupt handler address
        cpu.handleIrq();
        assert(cpu.popStack() == savedStatus); //check _status _registers
        ushort previousPC = cpu.popStack() | (cpu.popStack() << 8); //verify pc write
        assert(cpu._cycleCount == savedCycles + 7);
        assert(cpu._registers.pc == 0xC296);
        assert(previousPC == savedPC);
        //case 2 : interrupt disable bit is set
        cpu._status.i = true;
        savedCycles = cpu._cycleCount;
        ram.write16(cpu._irqAddress, 0x1111); //write interrupt handler address
        cpu.handleIrq();
        assert(cpu._cycleCount == savedCycles + 0);
        assert(cpu._registers.pc == 0xC296);
    }

    private ushort delegate(string,ubyte) decodeAddressMode(string instruction, ubyte opcode)
    {
        _pageBoundaryWasCrossed = false; //reset the page boundry crossing flag each time we decode the next address mode
        AddressingModeType addressModeCode =
            cast(AddressingModeType)(_addressModeTable[opcode]);

        switch (addressModeCode)
        {
        case AddressingModeType.IMPLIED:
            return null;
        case AddressingModeType.IMMEDIATE:
            return &(immediateAddressMode);
        case AddressingModeType.ACCUMULATOR:
        goto case AddressingModeType.IMPLIED;
        case AddressingModeType.ZEROPAGE:
        case AddressingModeType.ZEROPAGE_X:
        case AddressingModeType.ZEROPAGE_Y:
            return &(zeroPageAddressMode);
        case AddressingModeType.RELATIVE:
            return &(relativeAddressMode);
        case AddressingModeType.ABSOLUTE:
        case AddressingModeType.ABSOLUTE_X:
        case AddressingModeType.ABSOLUTE_Y:
            return &(absoluteAddressMode);
        case AddressingModeType.INDIRECT:
            return &(indirectAddressMode);
        case AddressingModeType.INDEXED_INDIRECT:
            return &(indexedIndirectAddressMode);
        case AddressingModeType.INDIRECT_INDEXED:
            return &(indirectIndexedAddressMode);
        default:
            throw new InvalidAddressingModeException(instruction, opcode);
        }
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();

        // Case 1: Implied & Accumulator
        // Case 2: Immediate
        // Case 3: Zero Page
        // Case 4: Absolute
        // Case 5: Indirect
        // Case 6: failure
        try
        {
            cpu.decodeAddressMode("KIL", 0x2A); // Invalid opcode
        }
        catch (InvalidAddressingModeException e)
        {} // this exception is expected; suppress it.
    }

    private ubyte decodeIndex(string instruction, ubyte opcode)
    {
        ubyte indexType = _addressModeTable[opcode] & 0x0F;
        switch (indexType)
        {
        case 0x00:
            return 0;
        case 0x01:
            return _registers.x;
        case 0x02:
            return _registers.y;
        default:
            throw new InvalidAddressIndexException(instruction, opcode);
        }
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        cpu._registers.x = 0x11;
        cpu._registers.y = 0x45;
        // Case 1: Non-indexed
        assert(cpu.decodeIndex("LDX",0xA6) == 0x00);
        // Case 2: X-indexed
        assert (cpu.decodeIndex("ADC", 0x7D) == cpu._registers.x);
        // case 3: Y-indexed
        assert (cpu.decodeIndex("ADC", 0x79) == cpu._registers.y);
        //case 4: failure
        try
        {
            cpu.decodeIndex("KIL", 0x2A); // Invalid opcode
        }
        catch (InvalidAddressIndexException e)
        {} // this exception is expected; suppress it.
    }

    //***** Instruction Implementation *****//
    // TODO: Add tracing so we can compare against nestest.log
    private void JMP(ubyte opcode)
    {
        auto addressModeFunction = decodeAddressMode("JMP", opcode);

        _registers.pc = addressModeFunction("JMP", opcode);
        _cycleCount += _cycleCountTable[opcode];
    }
    unittest
    {
        import std.stdio;
        auto cpu = new MOS6502;
        cpu.powerOn();
        auto ram = Console.ram;

        cpu._registers.pc = 0xC000;
        // Case 1: Absolute addressing
        ram.write(0xC000, 0x4C);     // JMP, absolute
        ram.write16(0xC001, 0xC005); // argument

        cpu.JMP(ram.read(cpu._registers.pc++));
        assert(cpu._registers.pc == 0xC005);

        // Case 2: Indirect addressing, page not boundary
        ram.write(0xC005, 0x6C);     // JMP, indirect address
        ram.write16(0xC006, 0xC00C); // address of final address
        ram.write16(0xC00C, 0xEE00);

        cpu.JMP(ram.read(cpu._registers.pc++));
        assert(cpu._registers.pc == 0xEE00);
    }

    private void ADC(ubyte opcode)
    {
        auto addressModeFunction = decodeAddressMode("ADC", opcode);
        auto addressMode     = _addressModeTable[opcode];

        auto ram = Console.ram;

        ushort a; // a = accumulator value
        ushort m; // m = operand
        ushort c; // c = carry value

        a = _registers.a;
        c = _status.c;

        if (addressMode == AddressingModeType.IMMEDIATE)
        {
            m = addressModeFunction("ADC", opcode);
        }
        else
        {
            m = ram.read(addressModeFunction("ADC", opcode));
            if (isIndexedMode(opcode) &&
                    (addressMode != AddressingModeType.INDIRECT_INDEXED) &&
                    (addressMode != AddressingModeType.ZEROPAGE_X))
            {
                if (_pageBoundaryWasCrossed)
                {
                    _cycleCount++;
                }
            }
        }

        auto result = cast(ushort)(a+m+c);
        // Check for overflow
        if (result > 255)
        {
            _registers.a = cast(ubyte)(result - 255);
            _status.c = 1;
        }
        else
        {
            _registers.a = cast(ubyte)(result);
            _status.c = 0;
        }

        checkAndSetZero(_registers.a);

        checkAndSetNegative(_registers.a);

        if (((_registers.a^m) & 0x80) == 0 && ((a^_registers.a) & 0x80) != 0)
        {
            _status.v = 1;
        }
        else
        {
            _status.v = 0;
        }

        _cycleCount += _cycleCountTable[opcode];
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        assert(cpu._registers.a == 0);
        auto ram = Console.ram;
        ulong cycles_start = 0;
        ulong cycles_end = 0;

        // Case 1: Immediate
        cycles_start = cpu._cycleCount;
        cpu._registers.pc = 0x0101;          // move to new page
        cpu._registers.a = 0x20;             // give an initial value other than 0
        cpu._status.c = 0;         // reset to 0
        ram.write(cpu._registers.pc, 0x40);  // write operand to memory

        cpu.ADC(0x69);            // execute ADC immediate
        cycles_end  = cpu._cycleCount; // get cycle count
        assert(cpu._registers.a == 0x60);    // 0x20 + 0x40 = 0x60
        assert((cycles_end - cycles_start) == 2); // verify cycles taken

        // Trigger overflow
        ram.write(cpu._registers.pc, 0xA0);
        cpu.ADC(0x69);
        assert(cpu._registers.a == 0x01);
        assert(cpu._status.c == 1);
        ram.write(cpu._registers.pc, 0x02);
        cpu.ADC(0x69);
        assert(cpu._status.c == 0);

        // @TODO continue testing each addressing mode

        // Case 4: Absolute
        cycles_start = cpu._cycleCount;
        cpu._registers.a = 0;
        cpu._registers.pc = 0x0400;
        ram.write16(cpu._registers.pc, 0xB00B);
        ram.write(0xB00B, 0x7D);
        cpu.ADC(0x6D);
        cycles_end  = cpu._cycleCount;
        assert(cpu._registers.a == 0x7D);
        assert((cycles_end - cycles_start) == 4);
    }

    private void AND(ubyte opcode)
    {
        auto addressModeFunction = decodeAddressMode("AND", opcode);
        auto addressMode         = _addressModeTable[opcode];

        auto ram = Console.ram;
        ubyte operand;

        if (addressMode == AddressingModeType.IMMEDIATE)
        {
            operand = cast(ubyte)(addressModeFunction("ADC", opcode));
        }

        _registers.a = (_registers.a & operand);
        _status.z = (_registers.a == 0   ? 1 : 0);
        _status.n = (_registers.a >= 128 ? 1 : 0);
        _cycleCount += _cycleCountTable[opcode];
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        assert(cpu._registers.a == 0);
        auto ram = Console.ram;
        ulong cycles_start = 0;
        ulong cycles_end = 0;

        // Case 1: Immediate
        uint expected_cycles = 2;
        ubyte expected_result;

        cycles_start = cpu._cycleCount;
        cpu._registers.pc = 0x0101;

        // iterate through all possible register/memory values and test them
        for (ushort op1 = 0; op1 < 256; op1++) { // operand1
            for (ushort op2 = 0; op2 < 256; op2++) { // operand 2
                cpu._status.z = 0;
                cpu._status.n = 0;
                cpu._registers.a = cast(ubyte)op1;
                ram.write(cpu._registers.pc, cast(ubyte)op2);

                cycles_start = cpu._cycleCount;

                cpu.AND(0x29);
                cycles_end = cpu._cycleCount;
                expected_result = cast(ubyte)op1 & cast(ubyte)op2;

                //writef("0b%.8b & 0b%.8b = 0b%.8b\n", op1, op2, expected_result);
                assert((cycles_end - cycles_start) == expected_cycles);
                assert(cpu._registers.a == expected_result);
                assert(cpu._registers.a == 0  ? cpu._status.z == 1 : cpu._status.z == 0);
                assert(cpu._registers.a >= 128 ? cpu._status.n == 1 : cpu._status.n == 0);
            }
        }
    }

    private void NOP(ubyte opcode)
    {
        _cycleCount += 2;
    }
    //If the negative flag is set then add the relative displacement to the program counter to cause a branch to a new location.
    private void BMI(ubyte opcode)
    {
        _cycleCount += 2;
        //Relative only
        ushort finalAddress = relativeAddressMode();
        if(_status.n)
        {
            if((_registers.pc / 0xFF) == (finalAddress / 0xFF))
            {
                _registers.pc = finalAddress;
                _cycleCount++;
            }
            else
            {
                _registers.pc = finalAddress;
                //goes to a new page
                _cycleCount +=2;
            }
        }
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        auto ram = Console.ram;
        //case 1 forward offset, n flag set, jumps page boundary (4 _cycleCount)
        cpu._status.n = 1;
        ram.write(cpu._registers.pc, 0x4C); // argument
        auto savedPC = cpu._registers.pc;
        auto savedCycles = cpu._cycleCount;
        cpu.BMI(0x30);
        assert(cpu._registers.pc == savedPC + 0x1 + 0x4C);
        assert(cpu._cycleCount == savedCycles + 0x4);
        //case 2 forward offset, n flag is clear, (2 cycles)
        cpu._status.n = 0;
        ram.write(cpu._registers.pc, 0x4C); // argument
        savedPC = cpu._registers.pc;
        savedCycles = cpu._cycleCount;
        cpu.BMI(0x30);
        assert(cpu._registers.pc == savedPC + 0x1); //for this case it should not branch
        assert(cpu._cycleCount == savedCycles + 0x2); //(2 cycles)
        //case 3 negative offset, n flag is set, (3 cycles)
        cpu._status.n = 1;
        ram.write(cpu._registers.pc, 0xF1); // (-15)
        savedPC = cpu._registers.pc;
        savedCycles = cpu._cycleCount;
        cpu.BMI(0x30);
        assert(cpu._registers.pc == savedPC + 1 - 0xF);
        assert(cpu._cycleCount == savedCycles + 0x3);
        //case 4 negative offset, n flag is clear (1 cycle)
        cpu._status.n = 0;
        ram.write(cpu._registers.pc, 0xF1); // argument
        savedPC = cpu._registers.pc;
        cpu.BMI(0x30);
        assert(cpu._registers.pc == savedPC + 0x1); //for this case it should not branch
    }

    //If the zero flag is clear then add the relative displacement to the program counter to cause a branch to a new location.
    private void BNE(ubyte opcode)
    {
        _cycleCount += 2;
        //Relative only
        ushort finalAddress = relativeAddressMode();
        if(!_status.z)
        {
            if((_registers.pc / 0xFF) == (finalAddress / 0xFF))
            {
                _registers.pc = finalAddress;
                _cycleCount++;
            }
            else
            {
                _registers.pc = finalAddress;
                //goes to a new page
                _cycleCount +=2;
            }
        }
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        auto ram = Console.ram;
        //case 1 forward offset, z flag clear, jumps page boundary (4 cycles)
        cpu._status.z = 0;
        ram.write(cpu._registers.pc, 0x4D); // argument
        auto savedPC = cpu._registers.pc;
        auto savedCycles = cpu._cycleCount;
        cpu.BNE(0xD0);
        assert(cpu._registers.pc == savedPC + 0x1 + 0x4D);
        assert(cpu._cycleCount == savedCycles + 0x4); //branch will cross a page boundary
        //case 2 forward offset, z flag is set, (2 cycles)
        cpu._status.z = 1;
        ram.write(cpu._registers.pc, 0x4D); // argument
        savedPC = cpu._registers.pc;
        savedCycles = cpu._cycleCount;
        cpu.BNE(0xD0);
        assert(cpu._registers.pc == savedPC + 0x1); //for this case it should not branch
        assert(cpu._cycleCount == savedCycles + 0x2); //(2 cycles)
        //case 3 negative offset, z flag is clear (3 cycles)
        cpu._status.z = 0;
        ram.write(cpu._registers.pc, 0xF1); // (-15)
        savedPC = cpu._registers.pc;
        savedCycles = cpu._cycleCount;
        cpu.BNE(0xD0);
        assert(cpu._registers.pc == savedPC + 1 - 0xF);
        assert(cpu._cycleCount == savedCycles + 0x3); //branch doesn't cross page boundary
        //case 4 negative offset, z flag is set (1 cycle)
        cpu._status.z = 1;
        ram.write(cpu._registers.pc, 0xF1); // argument
        savedPC = cpu._registers.pc;
        cpu.BNE(0xD0);
        assert(cpu._registers.pc == savedPC + 0x1); //for this case it should not branch
    }

    //If the negative flag is clear then add the relative displacement to the program counter to cause a branch to a new location.
    private void BPL(ubyte opcode)
    {
        _cycleCount += 2;
        //Relative only
        ushort finalAddress = relativeAddressMode();
        if(!_status.n)
        {
            if((_registers.pc / 0xFF) == (finalAddress / 0xFF))
            {
                _registers.pc = finalAddress;
                _cycleCount++;
            }
            else
            {
                _registers.pc = finalAddress;
                //goes to a new page
                _cycleCount +=2;
            }
        }
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        auto ram = Console.ram;
        //case 1 forward offset, n flag clear, jumps page boundary (4 cycles)
        cpu._status.n = 0;
        ram.write(cpu._registers.pc, 0x4D); // argument
        auto savedPC = cpu._registers.pc;
        auto savedCycles = cpu._cycleCount;
        cpu.BPL(0x10);
        assert(cpu._registers.pc == savedPC + 0x1 + 0x4D);
        assert(cpu._cycleCount == savedCycles + 0x4); //branch will cross a page boundary
        //case 2 forward offset, n flag is set, (2 cycles)
        cpu._status.n = 1;
        ram.write(cpu._registers.pc, 0x4D); // argument
        savedPC = cpu._registers.pc;
        savedCycles = cpu._cycleCount;
        cpu.BPL(0x10);
        assert(cpu._registers.pc == savedPC + 0x1); //for this case it should not branch
        assert(cpu._cycleCount == savedCycles + 0x2); //(2 cycles)
        //case 3 negative offset, n flag is clear (3 cycles)
        cpu._status.n = 0;
        ram.write(cpu._registers.pc, 0xF1); // (-15)
        savedPC = cpu._registers.pc;
        savedCycles = cpu._cycleCount;
        cpu.BPL(0x10);
        assert(cpu._registers.pc == savedPC + 1 - 0xF);
        assert(cpu._cycleCount == savedCycles + 0x3); //branch doesn't cross page boundary
        //case 4 negative offset, n flag is set (2 cycles)
        cpu._status.n = 1;
        ram.write(cpu._registers.pc, 0xF1); // argument
        savedPC = cpu._registers.pc;
        savedCycles = cpu._cycleCount;
        cpu.BPL(0x10);
        assert(cpu._registers.pc == savedPC + 0x1); //for this case it should not branch
        assert(cpu._cycleCount == savedCycles + 0x2);
    }

    //forces an interrupt to be fired. the _status register is copied to stack and bit 5 of the stored pc on the stack is set to 1
    private void BRK(ubyte opcode)
    {
        //the BRK instruction saves the PC at BRK+2 to stack, so increment PC by 1 to skip next byte
        _registers.pc++;
        pushStack(cast(ubyte)(_registers.pc >> 8)); //write PC high byte to stack
        pushStack(cast(ubyte)(_registers.pc));
        StatusRegister brkStatus = _status;
        //set b flag and write to stack
        brkStatus.b = 1;
        pushStack(brkStatus.asWord);
        auto _irqVectorAddress = Console.ram.read16(_irqAddress);
        _registers.pc = _irqVectorAddress; //brk handled similarly to _irq
        _cycleCount += 7;
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        auto ram = Console.ram;
        auto savedCycles = cpu._cycleCount;
        auto savedPC = cpu._registers.pc;
        auto savedStatus = cpu._status.asWord;
        ram.write16(cpu._irqAddress, 0x1744); //write interrupt handler address
        //increment PC by 1 to simulate fetch
        cpu._registers.pc++;
        cpu.BRK(0);
        assert(cpu.popStack() == (savedStatus | 0b10000)); //check _status _registers
        ushort previousPC = cpu.popStack() | (cpu.popStack() << 8); //verify pc write
        assert(cpu._cycleCount == savedCycles + 7);
        assert(cpu._registers.pc == 0x1744);
        assert(previousPC == savedPC + 2);
    }

    //If the overflow flag is clear then add the relative displacement to the program counter to cause a branch to a new location.
    private void BVC(ubyte opcode)
    {
        _cycleCount += 2;
        //Relative only
        ushort finalAddress = relativeAddressMode();
        if(!_status.v)
        {
            if((_registers.pc / 0xFF) == (finalAddress / 0xFF))
            {
                _registers.pc = finalAddress;
                _cycleCount++;
            }
            else
            {
                _registers.pc = finalAddress;
                //goes to a new page
                _cycleCount +=2;
            }
        }
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        auto ram = Console.ram;
        //case 1 forward offset, v flag clear, jumps page boundary (4 cycles)
        cpu._status.v = 0;
        ram.write(cpu._registers.pc, 0x5D); // argument
        auto savedPC = cpu._registers.pc;
        auto savedCycles = cpu._cycleCount;
        cpu.BVC(0x50);
        assert(cpu._registers.pc == savedPC + 0x1 + 0x5D);
        assert(cpu._cycleCount == savedCycles + 0x4); //branch will cross a page boundary
        //case 2 forward offset, v flag is set, (2 cycles)
        cpu._status.v = 1;
        ram.write(cpu._registers.pc, 0x4D); // argument
        savedPC = cpu._registers.pc;
        savedCycles = cpu._cycleCount;
        cpu.BVC(0x50);
        assert(cpu._registers.pc == savedPC + 0x1); //for this case it should not branch
        assert(cpu._cycleCount == savedCycles + 0x2); //(2 cycles)
        //case 3 negative offset, v flag is clear (3 cycles)
        cpu._status.v = 0;
        ram.write(cpu._registers.pc, 0xF1); // (-15)
        savedPC = cpu._registers.pc;
        savedCycles = cpu._cycleCount;
        cpu.BVC(0x50);
        assert(cpu._registers.pc == savedPC + 1 - 0xF);
        assert(cpu._cycleCount == savedCycles + 0x3); //branch doesn't cross page boundary
        //case 4 negative offset, v flag is set (2 cycles)
        cpu._status.v = 1;
        ram.write(cpu._registers.pc, 0xF1); // argument
        savedPC = cpu._registers.pc;
        savedCycles = cpu._cycleCount;
        cpu.BVC(0x50);
        assert(cpu._registers.pc == savedPC + 0x1); //for this case it should not branch
        assert(cpu._cycleCount == savedCycles + 0x2);
    }

    //If the overflow flag is set then add the relative displacement to the program counter to cause a branch to a new location.
    private void BVS(ubyte opcode)
    {
        _cycleCount += 2;
        //Relative only
        ushort finalAddress = relativeAddressMode();
        if(_status.v)
        {
            if((_registers.pc / 0xFF) == (finalAddress / 0xFF))
            {
                _registers.pc = finalAddress;
                _cycleCount++;
            }
            else
            {
                _registers.pc = finalAddress;
                //goes to a new page
                _cycleCount +=2;
            }
        }
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        auto ram = Console.ram;
        //case 1 forward offset, v flag set, jumps page boundary (4 cycles)
        cpu._status.v = 1;
        ram.write(cpu._registers.pc, 0x5C); // argument
        auto savedPC = cpu._registers.pc;
        auto savedCycles = cpu._cycleCount;
        cpu.BVS(0x70);
        assert(cpu._registers.pc == savedPC + 0x1 + 0x5C);
        assert(cpu._cycleCount == savedCycles + 0x4);
        //case 2 forward offset, v flag is clear, (2 cycles)
        cpu._status.v = 0;
        ram.write(cpu._registers.pc, 0x4C); // argument
        savedPC = cpu._registers.pc;
        savedCycles = cpu._cycleCount;
        cpu.BVS(0x70);
        assert(cpu._registers.pc == savedPC + 0x1); //for this case it should not branch
        assert(cpu._cycleCount == savedCycles + 0x2); //(2 cycles)
        //case 3 negative offset, v flag is set, (3 cycles)
        cpu._status.v = 1;
        ram.write(cpu._registers.pc, 0xF1); // (-15)
        savedPC = cpu._registers.pc;
        savedCycles = cpu._cycleCount;
        cpu.BVS(0x70);
        assert(cpu._registers.pc == savedPC + 1 - 0xF);
        assert(cpu._cycleCount == savedCycles + 0x3);
        //case 4 negative offset, v flag is clear (1 cycle)
        cpu._status.v = 0;
        ram.write(cpu._registers.pc, 0xF1); // argument
        savedPC = cpu._registers.pc;
        cpu.BVS(0x70);
        assert(cpu._registers.pc == savedPC + 0x1); //for this case it should not branch
    }

    //Clear carry flag
    private void CLC(ubyte opcode)
    {
        _status.c = 0;
        _cycleCount += 2;
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        auto savedCycles = cpu._cycleCount;
        cpu._status.c = 1;
        cpu.CLC(0x18);
        assert(cpu._status.c == 0);
        assert(cpu._cycleCount == savedCycles + 2);
    }

    //Clear decimal mode flag
    private void CLD(ubyte opcode)

    {
        _status.d = 0;
        _cycleCount += 2;
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        auto savedCycles = cpu._cycleCount;
        cpu._status.d = 1;
        cpu.CLD(0xD8);
        assert(cpu._status.d == 0);
        assert(cpu._cycleCount == savedCycles + 2);
    }

    //Clear interrupt disable flag
    private void CLI(ubyte opcode)
    {
        _status.i = 0;
        _cycleCount += 2;
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        auto savedCycles = cpu._cycleCount;
        cpu._status.i = 1;
        cpu.CLI(0x78);
        assert(cpu._status.i == 0);
        assert(cpu._cycleCount == savedCycles + 2);
    }

    //Clear overflow flag
    private void CLV(ubyte opcode)
    {
        _status.v = 0;
        _cycleCount += 2;
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        auto savedCycles = cpu._cycleCount;
        cpu._status.v = 1;
        cpu.CLV(0xB8);
        assert(cpu._status.v == 0);
        assert(cpu._cycleCount == savedCycles + 2);
    }

    //Decrements the X register by 1
    private void DEX(ubyte opcode)
    {
        _registers.x--;
        checkAndSetNegative(_registers.x);
        checkAndSetZero(_registers.x);
        _cycleCount += _cycleCountTable[opcode];
    }
    unittest //0xCA, 1 byte, 2 cycles
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        auto savedCycles = cpu._cycleCount;
        //case 1, x register is 0 and decremented to negative value
        cpu._registers.x = 0;
        cpu.DEX(0xCA);
        assert(cpu._status.n == 1);
        assert(cpu._status.z == 0);
        assert(cpu._cycleCount == savedCycles + 2);
        //case 2, x register is 1 and decremented to zero
        savedCycles = cpu._cycleCount;
        cpu._registers.x = 0;
        cpu.DEX(0xCA);
        assert(cpu._status.n == 1);
        assert(cpu._status.z == 0);
        assert(cpu._cycleCount == savedCycles + 2);
        //case 3, x register is positive and decremented to positive value
        savedCycles = cpu._cycleCount;
        cpu._registers.x = 10;
        cpu.DEX(0xCA);
        assert(cpu._status.n == 0);
        assert(cpu._status.z == 0);
        assert(cpu._cycleCount == savedCycles + 2);
    }

    //Decrements the Y register by 1
    private void DEY(ubyte opcode)
    {
        _registers.y--;
        checkAndSetNegative(_registers.y);
        checkAndSetZero(_registers.y);
        _cycleCount += _cycleCountTable[opcode];
    }
    unittest //0x88, 1 byte, 2 cycles
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        auto savedCycles = cpu._cycleCount;
        //case 1, y register is 0 and decremented to negative value
        cpu._registers.y = 0;
        cpu.DEY(0x88);
        assert(cpu._status.n == 1);
        assert(cpu._status.z == 0);
        assert(cpu._cycleCount == savedCycles + 2);
        //case 2, y register is 1 and decremented to zero
        savedCycles = cpu._cycleCount;
        cpu._registers.y = 0;
        cpu.DEY(0x88);
        assert(cpu._status.n == 1);
        assert(cpu._status.z == 0);
        assert(cpu._cycleCount == savedCycles + 2);
        //case 3, y register is positive and decremented to positive value
        savedCycles = cpu._cycleCount;
        cpu._registers.y = 45;
        cpu.DEY(0x88);
        assert(cpu._status.n == 0);
        assert(cpu._status.z == 0);
        assert(cpu._cycleCount == savedCycles + 2);
    }

    //An exclusive OR is performed, bit by bit, on the accumulator contents using the contents of a byte of memory.
    private void EOR(ubyte opcode)
    {
        auto addressModeFunction = decodeAddressMode("EOR", opcode);
        auto addressMode     = _addressModeTable[opcode];

        auto ram = Console.ram;

        ushort a = _registers.a; // a = accumulator value
        ushort m; // m = operand

        if (addressMode == AddressingModeType.IMMEDIATE)
        {
            m = addressModeFunction("EOR", opcode);
        }
        else
        {
            m = ram.read(addressModeFunction("EOR", opcode));

            if (isIndexedMode(opcode) &&
                    (addressMode != AddressingModeType.INDIRECT_INDEXED) &&
                    (addressMode != AddressingModeType.ZEROPAGE_X))
            {
                if (_pageBoundaryWasCrossed)
                {
                    _cycleCount++;
                }
            }
        }

        _registers.a = cast(ubyte)(a ^ m);
        checkAndSetZero(_registers.a);
        checkAndSetNegative(_registers.a);
        _cycleCount += _cycleCountTable[opcode];
    }
    /*
        Immediate 0x49 2
        Zero Page 0x45 3
        Zero Page,X 0x55 4
        Absolute 0x4D 4
        Absolute,X 0x5D 4(+1 if page crossed)
        Absolute,Y 0x59 4(+1 if page crossed)
        (Indirect,X) 0x41 6 <-indexed indirect
        (Indirect),Y 0x51 5(+1 if page crossed) <-indirect indexed
    */
    unittest
    {
        //verify all properties in imediate mode (final value of a, zero/negative flags, cycles)
        //then for all subsequent modes just verify the final value of a and cycles
        // 0xF ^ 0xB = 4 (z = 0, n = 0)
        // 0xF ^ 0xF0 = 0xFF (z = 0, n =1)
        // 0xF ^ 0xF = 0 (z = 1, n = 0)
        auto cpu = new MOS6502;
        auto ram = Console.ram;
        cpu.powerOn();
        //Case 1 mode 1, immediate mode no flags set
        auto savedCycles = cpu._cycleCount;
        cpu._registers.a = 0xF;
        ram.write(cpu._registers.pc, 0xB);
        cpu.EOR(0x49); //EOR immediate
        assert(cpu._registers.a == 4);
        assert(cpu._status.z == 0);
        assert(cpu._status.n == 0);
        assert(cpu._cycleCount == savedCycles + 2);
        //Case 2 mode 1, immediate mode negative flag set
        savedCycles = cpu._cycleCount;
        cpu._registers.a = 0xF;
        ram.write(cpu._registers.pc, 0xF0);
        cpu.EOR(0x49); //EOR immediate
        assert(cpu._registers.a == 0xFF);
        assert(cpu._status.z == 0);
        assert(cpu._status.n == 1);
        assert(cpu._cycleCount == savedCycles + 2);
        //Case 3 mode 1, immediate mode zero flag set
        savedCycles = cpu._cycleCount;
        cpu._registers.a = 0xF;
        ram.write(cpu._registers.pc, 0xF);
        cpu.EOR(0x49); //EOR immediate
        assert(cpu._registers.a == 0);
        assert(cpu._status.z == 1);
        assert(cpu._status.n == 0);
        assert(cpu._cycleCount == savedCycles + 2);
        //Case 4 mode 2, zero page mode no flags set
        savedCycles = cpu._cycleCount;
        cpu._registers.a = 0xF;
        ram.write(cpu._registers.pc, 0); //write address 0 to offset to zero page address 0
        ram.write(0, 0xB); //write to zero page address 0
        cpu.EOR(0x45); //EOR zero page
        assert(cpu._registers.a == 4);
        assert(cpu._status.z == 0);
        assert(cpu._status.n == 0);
        assert(cpu._cycleCount == savedCycles + 3);
        //Case 5 mode 3, zero page indexed no flags set
        savedCycles = cpu._cycleCount;
        cpu._registers.a = 0xF;
        ram.write(cpu._registers.pc, 2); //write address 2 to offset to zero page address 0
        cpu._registers.x = 4; //zero page address offset of 4
        ram.write(2+4, 0xB); //write to zero page address 2 + 4
        cpu.EOR(0x55); //EOR zero page indexed
        assert(cpu._registers.a == 4);
        assert(cpu._status.z == 0);
        assert(cpu._status.n == 0);
        assert(cpu._cycleCount == savedCycles + 4);
        //Case 6 mode 4, absolute zero flag set
        savedCycles = cpu._cycleCount;
        cpu._registers.a = 0xF;
        ram.write16(cpu._registers.pc, 0x1234); //write address 0x1234 to PC
        ram.write(0x1234, 0xF); //write operand m to address 0x1234
        cpu.EOR(0x4D); //EOR absolute
        assert(cpu._registers.a == 0);
        assert(cpu._status.z == 1);
        assert(cpu._status.n == 0);
        assert(cpu._cycleCount == savedCycles + 4);
        //Case 7 mode 5, absolute indexed x
        savedCycles = cpu._cycleCount;
        cpu._registers.a = 0xF;
        ram.write16(cpu._registers.pc, 0x1234); //write address 0x1234 to PC
        cpu._registers.x = 9;
        ram.write(0x1234+9, 0xF); //write operand m to address 0x1234+9
        cpu.EOR(0x5D); //EOR absolute
        assert(cpu._registers.a == 0);
        assert(cpu._status.z == 1);
        assert(cpu._status.n == 0);
        assert(cpu._cycleCount == savedCycles + 4);
        //Case 8 mode 6, absolute indexed y, page boundary crossed
        savedCycles = cpu._cycleCount;
        cpu._registers.a = 0xF;
        ram.write16(cpu._registers.pc, 0x1234); //write address 0x1234 to PC
        cpu._registers.y = 0xff;
        ram.write(0x1234+0xFF, 0xF); //write operand m to address 0x1234+0xFF
        cpu.EOR(0x59); //EOR absolute
        assert(cpu._registers.a == 0);
        assert(cpu._status.z == 1);
        assert(cpu._status.n == 0);
        assert(cpu._cycleCount == savedCycles + 5);
        //Case 9 mode 7, indexed indirect (target =
        savedCycles = cpu._cycleCount;
        cpu._registers.a = 0xF;
        cpu._registers.x = 4; //X register is 4. This will be added to the operand m (0xA in next line)
        ram.write(cpu._registers.pc, 0xA); //operand is 0xA
        ram.write(0xE, 0xF0); //write value 0xF0 to zero page address 0xA+4 = 0xE, which is what the target
        //address will be resolved to
        cpu.EOR(0x41);
        assert(cpu._registers.a == 0xFF);
        assert(cpu._status.z == 0);
        assert(cpu._status.n == 1);
        assert(cpu._cycleCount == savedCycles + 6);
        //case 10 mode 8, indirect indexed
    }

    //Increment memory address by 1
    //Affects Z and N flags
    private void INC(ubyte opcode)
    {
        auto instructionName = "INC";
        auto addressModeFunction = decodeAddressMode(instructionName, opcode);
        auto addressMode     = _addressModeTable[opcode];

        auto ram = Console.ram;
        ushort a; // a = operand, in our case the address to load and increment by 1
        ubyte m; // m = a + 1, stored back into a

        a = addressModeFunction(instructionName, opcode);
        m = (ram.read(a) + 1 ) & 0xFF; //gotta round
        ram.write(a, m);
        checkAndSetZero(m);
        checkAndSetNegative(m);
        _cycleCount += _cycleCountTable[opcode];
    }
    /*  Address Mode    Syntax        Opcode  I-Len  T-Cnt
        Zero Page       INC $A5        $E6      2     5
        Zero Page,X     INC $A5,X      $F6      2     6
        Absolute        INC $A5B6      $EE      3     6
        Absolute,X      INC $A5B6,X    $FE      3     7
    */
    unittest
    {
        auto cpu = new MOS6502;
        auto ram = Console.ram;
        cpu.powerOn();
        //Case 1 mode 1, zero page, n is set, z is unset
        auto savedCycles = cpu._cycleCount;
        ram.write(cpu._registers.pc, 5); //zero page address 5
        ram.write(5, 0x7F); //0x7F + 1 = 0x80, n flag (bit 7) gets set
        cpu.INC(0xE6);
        assert(ram.read(5) == cast(ubyte)(0x7F + 1));
        assert(cpu._status.z == 0);
        assert(cpu._status.n == 1);
        assert(cpu._cycleCount == savedCycles + 5);
        //Case 2 mode 1, zero page, z is set, n is unset
        savedCycles = cpu._cycleCount;
        ram.write(cpu._registers.pc, 5); //zero page address 5
        ram.write(5, 0xFF); //0xFF + 1 = 0x00, z flag is set since result is zero
        cpu.INC(0xE6);
        assert(ram.read(5) == cast(ubyte)(0xFF + 1));
        assert(cpu._status.z == 1);
        assert(cpu._status.n == 0);
        assert(cpu._cycleCount == savedCycles + 5);
        //Case 3 mode 1, zero page, n is unset, z is unset
        savedCycles = cpu._cycleCount;
        ram.write(cpu._registers.pc, 5); //zero page address 5
        ram.write(5, 0x70); //0x70 + 1 = 0x70, z and n flags unset
        cpu.INC(0xE6);
        assert(ram.read(5) == cast(ubyte)(0x70 + 1));
        assert(cpu._status.z == 0);
        assert(cpu._status.n == 0);
        assert(cpu._cycleCount == savedCycles + 5);
        //Case 4 mode 2, zero page indexed, n is set z is unset
        savedCycles = cpu._cycleCount;
        ram.write(cpu._registers.pc, 5); //zero page address 5
        cpu._registers.x = 6; //index is 6
        ram.write(5+6, 0x7F); //0x7F + 1 = 0x80, n flag (bit 7) gets set
        cpu.INC(0xF6);
        assert(ram.read(5+6) == cast(ubyte)(0x7F + 1));
        assert(cpu._status.z == 0);
        assert(cpu._status.n == 1);
        assert(cpu._cycleCount == savedCycles + 6);
        //Case 5 mode 3, absolute, z is set, n is unset
        savedCycles = cpu._cycleCount;
        ram.write16(cpu._registers.pc, 0x1234); //Absolute address 0x1234
        ram.write(0x1234, 0xFF); //0xFF + 1 = 0x00, z flag is set since result is zero
        cpu.INC(0xEE);
        assert(ram.read(0x1234) == cast(ubyte)(0xFF + 1));
        assert(cpu._status.z == 1);
        assert(cpu._status.n == 0);
        assert(cpu._cycleCount == savedCycles + 6);
        //Case 6 mode 4, absolute indexed, n is set, z is unset
        savedCycles = cpu._cycleCount;
        ram.write16(cpu._registers.pc, 0x1234); //Absolute address 0x1234
        cpu._registers.x = 8; //index is 8
        ram.write(0x1234 + 8, 0x7F); //0x7F + 1 = 0x80, n flag (bit 7) gets set
        cpu.INC(0xFE);
        assert(ram.read(0x1234 + 8) == cast(ubyte)(0x7F + 1));
        assert(cpu._status.z == 0);
        assert(cpu._status.n == 1);
        assert(cpu._cycleCount == savedCycles + 7);
    }

    //Increment X register by 1
    //Affects Z and N flags
    private void INX(ubyte opcode)
    {
        auto instructionName = "INX";
        auto m = cast(ubyte)(++_registers.x);
        checkAndSetZero(m);
        checkAndSetNegative(m);
        _cycleCount += _cycleCountTable[opcode];
    }
    /*  Address Mode    Syntax        Opcode  I-Len  T-Cnt
        Implied         INX            $E8      1     2
    */
    unittest
    {
        auto cpu = new MOS6502;
        auto ram = Console.ram;
        cpu.powerOn();
        //Case 1 mode 1, implied, n is set
        auto savedCycles = cpu._cycleCount;
        cpu._registers.x = 0x7F;
        cpu.INX(0xE8);
        assert(cpu._registers.x == cast(ubyte)(0x7F + 1));
        assert(cpu._status.z == 0);
        assert(cpu._status.n == 1);
        assert(cpu._cycleCount == savedCycles + 2);
        //Case 2 mode 1, implied, z is set
        savedCycles = cpu._cycleCount;
        cpu._registers.x = 0xFF;
        cpu.INX(0xE8);
        assert(cpu._registers.x == cast(ubyte)(0xFF + 1));
        assert(cpu._status.z == 1);
        assert(cpu._status.n == 0);
        assert(cpu._cycleCount == savedCycles + 2);

    }

    //Increment Y register by 1
    //Affects Z and N flags
    private void INY(ubyte opcode)
    {
        auto instructionName = "INY";
        auto m = cast(ubyte)(++_registers.y);
        checkAndSetZero(m);
        checkAndSetNegative(m);
        _cycleCount += _cycleCountTable[opcode];
    }
    /*  Address Mode    Syntax        Opcode  I-Len  T-Cnt
        Implied         INY            $C8      1     2
    */

    unittest
    {
        auto cpu = new MOS6502;
        auto ram = Console.ram;
        cpu.powerOn();
        //Case 1 mode 1, implied, n is set
        auto savedCycles = cpu._cycleCount;
        cpu._registers.y = 0x7F;
        cpu.INY(0xC8);
        assert(cpu._registers.y == cast(ubyte)(0x7F + 1));
        assert(cpu._status.z == 0);
        assert(cpu._status.n == 1);
        assert(cpu._cycleCount == savedCycles + 2);
        //Case 2 mode 1, implied, z is set
        savedCycles = cpu._cycleCount;
        cpu._registers.y = 0xFF;
        cpu.INY(0xC8);
        assert(cpu._registers.y == cast(ubyte)(0xFF + 1));
        assert(cpu._status.z == 1);
        assert(cpu._status.n == 0);
        assert(cpu._cycleCount == savedCycles + 2);

    }

    //Pushes A onto stacks, decrements SP by 1
    private void PHA(ubyte opcode)
    {
        auto instructionName = "PHA";
        ushort stackAddress = cast(ushort)(_stackBaseAddress + _registers.sp);
        auto ram = Console.ram;
        ram.write(stackAddress, _registers.a);
        _registers.sp = cast(ubyte)(--_registers.sp);
        _cycleCount += _cycleCountTable[opcode];
    }
    /*  Address Mode    Syntax        Opcode  I-Len  T-Cnt
        Implied         PHA            $48      1     3
    */
    unittest
    {
        auto cpu = new MOS6502;
        auto ram = Console.ram;
        auto savedSp = cpu._registers.sp;
        cpu.powerOn();
        //Case 1 mode 1, sp = FF
        auto savedCycles = cpu._cycleCount;
        cpu._registers.sp = 0xFF;
        cpu._registers.a = 0xAB;
        cpu.PHA(0x48);
        assert(cpu._registers.sp == 0xFE);
        assert(ram.read(cast(ushort)(cpu._stackBaseAddress + cpu._registers.sp + 1)) == 0xAB);
        assert(cpu._cycleCount == savedCycles + 3);
        //Case 2 mode 1, sp = 0, wraparound to 0xFF
        savedCycles = cpu._cycleCount;
        cpu._registers.sp = 0x00;
        cpu._registers.a = 0xCD;
        cpu.PHA(0x48);
        assert(cpu._registers.sp == 0xFF);
        assert(ram.read(cast(ushort)(cpu._stackBaseAddress + cast(ubyte)(cpu._registers.sp + 1))) == 0xCD);
        assert(cpu._cycleCount == savedCycles + 3);
    }

    //Pushes _status register onto stacks, decrements SP by 1
    private void PHP(ubyte opcode)
    {
        auto instructionName = "PHP";
        ushort stackAddress = cast(ushort)(_stackBaseAddress + _registers.sp);
        auto ram = Console.ram;
        ram.write(stackAddress, _status.asWord);
        _registers.sp = cast(ubyte)(--_registers.sp);
        _cycleCount += _cycleCountTable[opcode];
    }
    /*  Address Mode    Syntax        Opcode  I-Len  T-Cnt
        Implied         PHP            $08      1     3
    */
    unittest
    {
        auto cpu = new MOS6502;
        auto ram = Console.ram;
        auto savedSp = cpu._registers.sp;
        cpu.powerOn();
        //Case 1 mode 1, sp = FF
        auto savedCycles = cpu._cycleCount;
        cpu._registers.sp = 0xFF;
        cpu._status.asWord = 0xAB;
        cpu.PHP(0x08);
        assert(cpu._registers.sp == 0xFE);
        assert(ram.read(cast(ushort)(cpu._stackBaseAddress + cpu._registers.sp + 1)) == 0xAB);
        assert(cpu._cycleCount == savedCycles + 3);
        //Case 2 mode 1, sp = 0, wraparound to 0xFF
        savedCycles = cpu._cycleCount;
        cpu._registers.sp = 0x00;
        cpu._status.asWord = 0xCD;
        assert(cpu._status.asWord == (0xCD | 0b0010_0000)); //writing to _status register will always cause bit 6 to be set
        cpu.PHP(0x08);
        assert(cpu._registers.sp == 0xFF);
        assert(ram.read(cast(ushort)(cpu._stackBaseAddress + cast(ubyte)(cpu._registers.sp + 1))) == (0xCD | 0b0010_0000));
        assert(cpu._cycleCount == savedCycles + 3);
    }

    //Pulls/pops A off the stacks (and into A), increments SP by 1
    //Affects N and Z flags
    private void PLA(ubyte opcode)
    {
        auto instructionName = "PLA";
        _registers.sp = cast(ubyte)(++_registers.sp);
        ushort stackAddress = cast(ushort)(_stackBaseAddress + _registers.sp);
        auto ram = Console.ram;
        _registers.a = ram.read(stackAddress);
        checkAndSetZero(_registers.a);
        checkAndSetNegative(_registers.a);
        _cycleCount += _cycleCountTable[opcode];
    }
    /*  Address Mode    Syntax        Opcode  I-Len  T-Cnt
        Implied         PLA            $68      1     4
    */
    unittest
    {
        import std.stdio;

        auto cpu = new MOS6502;
        auto ram = Console.ram;
        auto savedSp = cpu._registers.sp;
        cpu.powerOn();
        //Case 1 mode 1, sp = FF
        auto savedCycles = cpu._cycleCount;
        cpu._registers.sp = 0xFF;
        cpu._registers.a = 0x00;
        cpu.pushStack(0xAB);
        assert(cpu._registers.sp == 0xFE);
        cpu.PLA(0x68);
        assert(cpu._registers.sp == 0xFF);
        assert(cpu._registers.a == 0xAB);
        assert(cpu._cycleCount == savedCycles + 4);
        //Case 2 mode 1, sp = 0, wraparound to 0xFF and then back to 0
        savedCycles = cpu._cycleCount;
        cpu._registers.sp = 0x00;
        cpu._registers.a = 0x00;
        cpu.pushStack(0xCD);
        assert(cpu._registers.sp == 0xFF);
        cpu.PLA(0x68);
        assert(cpu._registers.sp == 0x00);
        assert(cpu._registers.a == 0xCD);
        assert(cpu._cycleCount == savedCycles + 4);
    }

    //Pulls/pops _status register off the stacks (and into P), increments SP by 1
    private void PLP(ubyte opcode)
    {
        auto instructionName = "PLP";
        _registers.sp = cast(ubyte)(++_registers.sp);
        ushort stackAddress = cast(ushort)(_stackBaseAddress + _registers.sp);
        auto ram = Console.ram;
        _status.asWord = ram.read(stackAddress);
        _cycleCount += _cycleCountTable[opcode];
    }
    /*  Address Mode    Syntax        Opcode  I-Len  T-Cnt
        Implied         PLP            $28      1     4
    */
    unittest
    {
        auto cpu = new MOS6502;
        auto ram = Console.ram;
        auto savedSp = cpu._registers.sp;
        cpu.powerOn();
        //Case 1 mode 1, sp = FF
        auto savedCycles = cpu._cycleCount;
        cpu._registers.sp = 0xFF;
        cpu._status.asWord = 0x00;
        cpu.pushStack(0xAB);
        assert(cpu._registers.sp == 0xFE);
        cpu.PLP(0x28);
        assert(cpu._registers.sp == 0xFF);
        assert(cpu._status.asWord == 0xAB);
        assert(cpu._cycleCount == savedCycles + 4);
        //Case 2 mode 1, sp = 0, wraparound to 0xFF and then back to 0
        savedCycles = cpu._cycleCount;
        cpu._registers.sp = 0x00;
        cpu._status.asWord = 0x00;
        cpu.pushStack(0xCD);
        assert(cpu._registers.sp == 0xFF);
        cpu.PLP(0x28);
        assert(cpu._registers.sp == 0x00);
        assert(cpu._status.asWord == (0xCD | 0b0010_0000)); //writing to _status register will always cause bit 6 to be set
        assert(cpu._cycleCount == savedCycles + 4);
    }

    //Rotates a byte by shifting to the left 1 bit. Carry flag is placed into bit 0, Bit 7 is placed into carry flag, and bit 6 is placed
    //into negative flag, and sets z flag with the result of the rotate
    private void ROL(ubyte opcode)
    {
        auto instructionName = "ROL";
        auto addressModeFunction = decodeAddressMode(instructionName, opcode);
        auto addressMode     = _addressModeTable[opcode];

        auto ram = Console.ram;
        ushort operand; // operand for non accumulator modes
        ubyte accumulator; //operand for accumulator mode

        if(addressMode == AddressingModeType.ACCUMULATOR)
        {
            auto carry = _status.c;
            _status.c = cast(bool)(_registers.a & 0x80); //copy bit 7 into carry
            _status.n = cast(bool)(_registers.a & 0x40); //copy bit 6 into negative
            _registers.a <<= 1; //shift a left by 1 bit (bit 0 should be 1 now)
            _registers.a |= carry; //copy carry to bit 0
            checkAndSetZero(_registers.a);
        }
        else //TODO
        {
            operand = addressModeFunction(instructionName, opcode);            
        }
    }
    /*  Address Mode    Syntax        Opcode  I-Len  T-Cnt  
        Accumulator     ROL A          $2A      1    2   
        Zero Page       ROL $A5        $26      2    5   
        Zero Page,X     ROL $A5,X      $36      2    6   
        Absolute        ROL $A5B6      $2E      3    6   
        Absolute,X      ROL $A5B6,X    $3E      3    7    
    */
    unittest //TODO
    {
    }

    //***** Addressing Modes *****//
    // Immediate address mode is the operand is a 1 byte constant following the
    // opcode so read the constant, increment pc by 1 and return it
    private ushort immediateAddressMode(string instruction = "", ubyte opcode = 0)
    {
        return Console.ram.read(_registers.pc++);
    }
    unittest
    {
        ubyte result = 0;
        auto cpu = new MOS6502;
        cpu.powerOn();

        Console.ram.write(cpu._registers.pc+0, 0x7D);
        result = cast(ubyte)(cpu.immediateAddressMode());
        assert(result == 0x7D);
        assert(cpu._registers.pc == 0xC001);
    }

    /* zero page address indicates that byte following the operand is an address
     * from 0x0000 to 0x00FF (256 bytes). in this case we read in the address
     * and return it
     *
     * zero page index address indicates that byte following the operand is an
     * address from 0x0000 to 0x00FF (256 bytes). in this case we read in the
     * address then offset it by the value in a specified register (X, Y, etc)
     * when calling this function you must provide the value to be indexed by
     * for example an instruction that is STY Operand, Means we will take
     * operand, offset it by the value in Y register
     * and correctly round it and return it as a zero page memory address */

    private ushort zeroPageAddressMode(string instruction, ubyte opcode)
    {
        ubyte address = Console.ram.read(_registers.pc++);
        ubyte offset = decodeIndex(instruction, opcode);
        ushort finalAddress = cast(ubyte)(address + offset);
        return finalAddress;
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        // write address 0x7D to PC
        Console.ram.write(cpu._registers.pc, 0x7D);
        // zero page addressing mode will read address stored at cpu._registers.pc which is
        // 0x7D, then return the value stored in ram at 0x007D which should be
        // 0x55
        assert(cpu.zeroPageAddressMode("ADC",0x65) == 0x7D);
        assert(cpu._registers.pc == 0xC001);

        // set ram at PC to a zero page indexed address, indexing y register
        Console.ram.write(cpu._registers.pc, 0xFF);
        //set X register to 5
        cpu._registers.x = 5;
        // example STY will add operand to y register, and return that
        // FF + 5 = overflow to 0x04
        assert(cpu.zeroPageAddressMode("ADC", 0x75) == 0x04);
        assert(cpu._registers.pc == 0xC002);
        // set ram at PC to a zero page indexed address, indexing y register
        Console.ram.write(cpu._registers.pc, 0x10);
        //set X register to 5
        cpu._registers.y = 5;
        // example STY will add operand to y register, and return that
        assert(cpu.zeroPageAddressMode("LDX", 0xB6) == 0x15);
        assert(cpu._registers.pc == 0xC003);
    }

    /* zero page index address indicates that byte following the operand is an
     * address from 0x0000 to 0x00FF (256 bytes). in this case we read in the
     * address then offset it by the value in a specified register (X, Y, etc)
     * when calling this function you must provide the value to be indexed by
     * for example an instruction that is
     * STY Operand, Y
     * Means we will take operand, offset it by the value in Y register
     * and correctly round it and return it as a zero page memory address */
    /*ushort zeroPageIndexedAddressMode(string instruction, ubyte opcode)
    {
        ubyte indexValue = decodeIndex(instruction, opcode);
        ubyte address = Console.ram.read(_registers.pc++);
        address += indexValue;
        return address;
    } */

    /* for relative address mode we will calculate an adress that is
     * between -128 to +127 from the PC + 1
     * used only for branch instructions
     * fi_rst byte after the opcode is the relative offset as a
     * signed byte. the offset is calculated from the position after the
     * operand so it is in actuality -126 to +129 from where the opcode
     * resides */
    private ushort relativeAddressMode(string instruction = "", ubyte opcode = 0)
    {
        byte offset = cast(byte)(Console.ram.read(_registers.pc++));
        //int finalAddress = (cast(int)_registers.pc + offset);
        ushort finalAddress = cast(ushort)((_registers.pc) + offset);

        checkPageCrossed(_registers.pc, finalAddress);
        return cast(ushort)(finalAddress);
    }
    unittest
    {
        auto cpu = new MOS6502;
        ushort result = 0;
        cpu.powerOn();
        // Case 1 & 2 : Relative Addess forward
        // relative offset will be +1
        Console.ram.write(cpu._registers.pc, 0x01);
        result = cpu.relativeAddressMode(); // parameters dont matter
        assert(cpu._registers.pc == 0xC001);
        assert(result == 0xC002);
        //relative offset will be +3
        Console.ram.write(cpu._registers.pc, 0x03);
        result = cpu.relativeAddressMode();
        assert(cpu._registers.pc == 0xC002);
        assert(result == 0xC005);
        // Case 3: Relative Addess backwards
        // relative offset will be -6 from 0xC003
        // offset is from 0xC003 because the address mode
        // decode function increments PC by 1 before calculating
        // the final position
        ubyte off = cast(ubyte)-6;
        Console.ram.write(cpu._registers.pc, off );
        result = cpu.relativeAddressMode();
        assert(cpu._registers.pc == 0xC003);
        assert(result == 0xBFFD);
        // Case 4: Relative address backwards underflow when PC = 0
        // Result will underflow as 0 - 6 = -6 =
        cpu._registers.pc = 0x0;
        Console.ram.write(cpu._registers.pc, off);
        result = cpu.relativeAddressMode();
        assert(result == 0xFFFB);
        // Case 5: Relative address forwards oferflow when PC = 0xFFFE
        // and address is + 2
        cpu._registers.pc = 0xFFFE;
        Console.ram.write(cpu._registers.pc, 0x02);
        result = cpu.relativeAddressMode();
        assert(result == 0x01);
    }

    //absolute address mode reads 16 bytes so increment pc by 2
    private ushort absoluteAddressMode(string instruction, ubyte opcode)
    {
        ushort address = Console.ram.read16(_registers.pc);
        ubyte offset = decodeIndex(instruction, opcode);
        ushort finalAddress = cast(ushort)(address + offset);

        checkPageCrossed(address, finalAddress);
        _registers.pc += 0x2;
        return finalAddress;
    }
    unittest
    {
        auto cpu = new MOS6502;
        ushort result = 0;
        cpu.powerOn();

        // Case 1: Absolute addressing is dead-simple. The argument of the
        // in this case is the address stored in the next two byts.

        // write address 0x7D00 to PC
        Console.ram.write16(cpu._registers.pc, 0x7D00);

        result = cpu.absoluteAddressMode("ADC", 0x6D);
        assert(result == 0x7D00);
        assert(cpu._registers.pc == 0xC002);

        // Case 2: Absolute indexed addressing is dead-simple. The argument of the
        // in this case is the address stored in the next two bytes, which is added
        // to third argument which in the index, which is usually X or Y register
        // write address 0x7D00 to PC
        Console.ram.write16(cpu._registers.pc, 0x7D00);
        cpu._registers.y = 5;
        result = cpu.absoluteAddressMode("ADC", 0x79);
        assert(result == 0x7D05);
        assert(cpu._registers.pc == 0xC004);
    }

    /* absolute indexed address mode reads 16 bytes so increment pc by 2
    private ushort absoluteIndexedAddressMode(string instruction, ubyte opcode)
    {
        ubyte indexType = _addressModeTable[opcode] & 0xF;
        ubyte indexValue = decodeIndex(instruction, opcode);

        ushort data = Console.ram.read16(_registers.pc);
        _registers.pc += 0x2;
        data += indexValue;
        return data;
    }
    unittest
    {
        auto cpu = new MOS6502;
        ushort result = 0;
        cpu.powerOn();

        // Case 1: Absolute indexed addressing is dead-simple. The argument of the
        // in this case is the address stored in the next two bytes, which is added
        // to third argument which in the index, which is usually X or Y register
        // write address 0x7D00 to PC
        Console.ram.write16(cpu._registers.pc, 0x7D00);
        cpu._registers.y = 5;
        result = cpu.absoluteIndexedAddressMode(cpu._registers.y);
        assert(result == 0x7D05);
        assert(cpu._registers.pc == 0xC002);
    } */

    private ushort  indirectAddressMode(string instruction = "", ubyte opcode = 0)
    {
        ushort effectiveAddress = Console.ram.read16(_registers.pc);
        ushort returnAddress = Console.ram.buggyRead16(effectiveAddress); // does not increment _registers.pc

        _registers.pc += 0x2;  // increment program counter for fi_rst read16 op
        return returnAddress;
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();

        // Case1: Straightforward indirection.
        // Argument is an address contianing an address.
        Console.ram.write16(cpu._registers.pc, 0x0D10);
        Console.ram.write16(0x0D10, 0x1FFF);
        assert(cpu.indirectAddressMode() == 0x1FFF);
        assert(cpu._registers.pc == 0xC002);

        // Case 2:
        // 6502 has a bug with the JMP instruction in indirect mode. If
        // the argument is $10FF, it will read the lower byte as $FF, and
        // then fail to increment the higher byte from $10 to $11,
        // resulting in a read from $1000 rather than $1100 when loading the
        // second byte

        // Place the high and low bytes of the operand in the proper places;
        Console.ram.write(0x10FF, 0x55); // low byte
        Console.ram.write(0x1000, 0x7D); // misplaced high byte

        // Set up the program counter to read from $10FF and trigger the "bug"
        Console.ram.write16(cpu._registers.pc, 0x10FF);

        assert(cpu.indirectAddressMode() == 0x7D55);
        assert(cpu._registers.pc == 0xC004);
    }

    // indexed indirect mode is a mode where the byte following the opcode is a zero page address
    // which is then added to the X register (passed in). This memory address will then be read
    // to get the final memory address and returned
    // This mode does zero page wrapping
    // Additionally it will read the target address as 16 bytes
    private ushort indexedIndirectAddressMode(string instruction = "", ubyte opcode = 0)
    {
        ubyte zeroPageAddress = Console.ram.read(_registers.pc++);
        ubyte targetAddress = cast(ubyte)(zeroPageAddress + _registers.x);
        //return Console.ram.read16(cast(ushort)targetAddress);
        return targetAddress;
    }
    unittest
    {

        auto cpu = new MOS6502;
        cpu.powerOn();
        // Case 1 : no zero page wrapping
        //write zero page addres 0x0F to PC
        Console.ram.write(cpu._registers.pc, 0x0F);
        //indexed indirect with an idex of 7 will produce: 0x0F + 0x7 = 0x16
        cpu._registers.x = 0x7;
        ushort address = cpu.indexedIndirectAddressMode();
        assert(address == 0x16);

        // Case 1 : zero page wrapping
        //write zero page addres 0xFF to PC
        Console.ram.write(cpu._registers.pc, 0xFF);
        //indexed indirect with an idex of 7 will produce: 0xFF + 0x7 = 0x06
        cpu._registers.x = 0x7;
        address = cpu.indexedIndirectAddressMode();
        assert(address == 0x06);

    }

    // indirect indexed is similar to indexed indirect, except the index offset
    // is added to the final memory value instead of to the zero page address
    // so this mode will read a zero page address as the next byte after the
    // operand, look up a 16 bit value in the zero page, add the index to that
    // and return it as the final address. note that there is no zero page
    // address wrapping
    private ushort indirectIndexedAddressMode(string instruction = "", ubyte opcode = 0)
    {
        ubyte zeroPageAddress = Console.ram.read(_registers.pc++);
        ushort targetAddress = Console.ram.read16(cast(ushort) zeroPageAddress);
        return cast(ushort) (targetAddress + _registers.y);
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();
        // Case 1 : no wrapping around address space
        //write zero page addres 0x0F to PC
        Console.ram.write(cpu._registers.pc, 0x0F);
        //write address 0xCDAB to zero page addres 0x0F and 0x10
        Console.ram.write(0x0F, 0xAB);
        Console.ram.write(0x10, 0xCD);
        //indirect indexed with an idex of 7
        cpu._registers.y = 0x7;
        ushort address = cpu.indirectIndexedAddressMode();
        assert(address == 0xCDAB + 0x7);
        // Case 2 : wrapping around the 16 bit address space
        //write zero page addres 0x0F to PC
        Console.ram.write(cpu._registers.pc, 0x0F);
        //write address 0xFFFE to zero page addres 0x0F and 0x10
        Console.ram.write(0x0F, 0xFE);
        Console.ram.write(0x10, 0xFF);
        //indirect indexed with an idex of 7
        cpu._registers.y = 0x7;
        address = cpu.indirectIndexedAddressMode();
        assert(address == cast(ushort)(0xFFFE + 7));
    }

    private void setNmi()
    {
        _nmi = true;
    }

    private void setReset()
    {
        _rst = true;
    }

    private void setIrq()
    {
        _irq = true;
    }

    //pushes a byte onto the stack, decrements stack pointer
    private void pushStack(ubyte data)
    {
        ushort stackAddress = cast(ushort)(_stackBaseAddress + _registers.sp);
        //add some logic here to possibly check for stack overflow conditions
        Console.ram.write(stackAddress, data);
        _registers.sp--;
    }
    unittest
    {
    }
    //increments stack pointer and returns the byte from the top of the stack
    private ubyte popStack()
    {
        //remember sp points to the next EMPTY stack location so we increment SP fi_rst
        //to get to the last stack value
        _registers.sp++;
        ushort stackAddress = cast(ushort)(_stackBaseAddress + _registers.sp);
        return Console.ram.read(stackAddress);
    }
    unittest
    {
    }

    private void checkPageCrossed(ushort startingAddress, ushort finalAddress)
    {
        ubyte pageOne = (startingAddress >> 8) & 0x00FF;
        ubyte pageTwo = (finalAddress >> 8) & 0x00FF;

        _pageBoundaryWasCrossed = (pageOne != pageTwo);
    }
    unittest
    {
        auto cpu = new MOS6502;
        assert(cpu._pageBoundaryWasCrossed  == false);

        cpu.checkPageCrossed(0x00FF, 0x0100);
        assert(cpu._pageBoundaryWasCrossed == true);
        cpu.checkPageCrossed(0x00FF, 0x00FF);
        assert(cpu._pageBoundaryWasCrossed  == false);
        cpu.checkPageCrossed(0x0000, 0x00FF);
        assert(cpu._pageBoundaryWasCrossed  == false);
        cpu.checkPageCrossed(0x0000, 0x0100);
        assert(cpu._pageBoundaryWasCrossed  == true);
    }

    private static bool isIndexedMode(ubyte opcode)
    {
        ubyte addressType = _addressModeTable[opcode];
        ubyte lowerNybble = addressType & 0xF;

        if (addressType == AddressingModeType.IMMEDIATE) return false;

        return (lowerNybble != 0);
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.powerOn();

        assert(isIndexedMode(0x6D) == false); // ADC, Absolute
        assert(isIndexedMode(0x7D) == true);  // ADC, Absolute,X
        assert(isIndexedMode(0x79) == true);  // ADC, Absolute, Y
    }

    //checks the value to see if we need to set the negative flag
    //by checking bit 7
    private void checkAndSetNegative(byte value)
    {
        if(value & 0x80) //if bit 7 is set then negative flag is set
            _status.n = 1;
        else
            _status.n = 0;
    }
    unittest
    {
        auto cpu = new MOS6502;

        cpu.checkAndSetNegative(5);
        assert(cpu._status.n == 0);
        cpu.checkAndSetNegative(-5);
        assert(cpu._status.n == 1);
        cpu.checkAndSetNegative(45);
        assert(cpu._status.n == 0);
    }

    //checks the value to see if it's zero and sets zero flag appropriately
    private void checkAndSetZero(byte value)
    {
        if(value == 0 )
            _status.z = 1;
        else
            _status.z = 0;
    }
    unittest
    {
        auto cpu = new MOS6502;
        cpu.checkAndSetZero(5);
        assert(cpu._status.z == 0);
        cpu.checkAndSetZero(-5);
        assert(cpu._status.z == 0);
        cpu.checkAndSetZero(0);
        assert(cpu._status.z == 1);
    }

    private enum AddressingModeType : ubyte
    {
        IMPLIED     = 0x01,
        IMMEDIATE   = 0x10,
        ACCUMULATOR = 0xA0,
        ZEROPAGE    = 0xB0,
        ZEROPAGE_X  = 0xB1,
        ZEROPAGE_Y  = 0xB2,
        RELATIVE    = 0xC0,
        ABSOLUTE    = 0xD0,
        ABSOLUTE_X  = 0xD1,
        ABSOLUTE_Y  = 0xD2,
        INDIRECT    = 0xF0,
        INDEXED_INDIRECT = 0xF1, // INDIRECT_X
        INDIRECT_INDEXED = 0xF2  // INDIRECT_Y
    }

    // For legibility and convenience
    private class Registers
    {
        ushort pc; // program counter

        ubyte a;  // accumulator
        ubyte x;  // x-index
        ubyte y;  // y-index
        ubyte sp; // stack pointer
    }

    private ulong _cycleCount;    // total cycles executed
    private bool _pageBoundaryWasCrossed;

    private Registers _registers;
    private StatusRegister _status; // Stored as a bit-field

    private bool _nmi; // non maskable interrupt line
    private bool _rst; // reset interrupt line
    private bool _irq; //software interrupt request line

    private immutable ushort _nmiAddress = 0xFFFA;
    private immutable ushort _resetAddress = 0xFFFC;
    private immutable ushort _irqAddress = 0xFFFE;
    private immutable ushort _stackBaseAddress = 0x0100;
    private immutable ushort _stackTopAddress = 0x01FF;

    static immutable ubyte[256] _cycleCountTable = [
        // 0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F
        7, 6, 0, 8, 3, 3, 5, 5, 3, 2, 2, 2, 4, 4, 6, 6, // 0
        2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7, // 1
        6, 6, 0, 8, 3, 3, 5, 5, 4, 2, 2, 2, 4, 4, 6, 6, // 2
        2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7, // 3
        6, 6, 0, 8, 3, 3, 5, 5, 3, 2, 2, 2, 3, 4, 6, 6, // 4
        2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7, // 5
        6, 6, 0, 8, 3, 3, 5, 5, 4, 2, 2, 2, 5, 4, 6, 6, // 6
        2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7, // 7
        2, 6, 2, 6, 3, 3, 3, 3, 2, 2, 2, 2, 4, 4, 4, 4, // 8
        2, 6, 0, 6, 4, 4, 4, 4, 2, 5, 2, 5, 5, 5, 5, 5, // 9
        2, 6, 2, 6, 3, 3, 3, 3, 2, 2, 2, 2, 4, 4, 4, 4, // A
        2, 5, 0, 5, 4, 4, 4, 4, 2, 4, 2, 4, 4, 4, 4, 4, // B
        2, 6, 2, 8, 3, 3, 5, 5, 2, 2, 2, 2, 4, 4, 6, 6, // C
        2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7, // D
        2, 6, 2, 8, 3, 3, 5, 5, 2, 2, 2, 2, 4, 4, 6, 6, // E
        2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7 ]; // F


    private static immutable ubyte[256] _addressModeTable= [
        //  0      1      2      3      4      5      6      7
        //  8      9      A      B      C      D      E      F
        0x01,  0xF2,  0x00,  0xF2,  0xB0,  0xB0,  0xB0,  0xB0, // 0
        0x01,  0x10,  0xA0,  0x00,  0xD0,  0xD0,  0xD0,  0xD0, // 0
        0xC0,  0xF1,  0x00,  0xF1,  0xB1,  0xB1,  0xB1,  0xB1, // 1
        0x01,  0xD2,  0x00,  0xD2,  0xD1,  0xD1,  0xD1,  0xD1, // 1
        0xD0,  0xF2,  0x00,  0xF2,  0xB0,  0xB0,  0xB0,  0xB0, // 2
        0x01,  0x10,  0xA0,  0x00,  0xD0,  0xD0,  0xD0,  0xD0, // 2
        0xC2,  0xF1,  0x00,  0xF1,  0xB1,  0xB1,  0xB1,  0xB1, // 3
        0x01,  0xD2,  0x00,  0xD2,  0xD1,  0xD1,  0xD1,  0xD1, // 3
        0x01,  0xF1,  0x00,  0xF2,  0xB0,  0xB0,  0xB0,  0xB0, // 4
        0x01,  0x10,  0xA0,  0x00,  0xD0,  0xD0,  0xD0,  0xD0, // 4
        0xC0,  0xF1,  0x00,  0xF1,  0xB1,  0xB1,  0xB1,  0xB1, // 5
        0x01,  0xD2,  0x00,  0xD2,  0xD1,  0xD1,  0xD1,  0xD1, // 5
        0xF1,  0xF2,  0x00,  0xF2,  0xB0,  0xB0,  0xB0,  0xB0, // 6
        0x01,  0x10,  0xA0,  0x00,  0xF0,  0xD0,  0xD0,  0xD0, // 6
        0xC0,  0xF1,  0x00,  0xF1,  0xB1,  0xB1,  0xB1,  0xB1, // 7
        0x01,  0xD2,  0x00,  0xD2,  0xD1,  0xD1,  0xD1,  0xD1, // 7
        0x00,  0xF2,  0x00,  0xF2,  0xB0,  0xB0,  0xB0,  0xB0, // 8
        0x01,  0x00,  0x01,  0x00,  0xD0,  0xD0,  0xD0,  0xD0, // 8
        0xC0,  0xF1,  0x00,  0xF1,  0xB1,  0xB1,  0xB2,  0xB2, // 9
        0x01,  0xD2,  0x01,  0x00,  0xD1,  0xD1,  0xD2,  0xD2, // 9
        0x10,  0xF2,  0x10,  0xF2,  0xB0,  0xB0,  0xB0,  0xB0, // A
        0x01,  0x10,  0x01,  0x00,  0xD0,  0xD0,  0xD0,  0xD0, // A
        0xC0,  0xF1,  0x00,  0xF1,  0xB1,  0xB1,  0xB2,  0xB2, // B
        0x01,  0xD2,  0x01,  0xD2,  0xD1,  0xD1,  0xD2,  0xD2, // B
        0x10,  0xF1,  0x00,  0xF2,  0xB0,  0xB0,  0xB0,  0xB0, // C
        0x01,  0x10,  0x01,  0x00,  0xD0,  0xD0,  0xD0,  0xD0, // C
        0xC0,  0xF1,  0x00,  0xF1,  0xB1,  0xB1,  0xB1,  0xB1, // D
        0x01,  0xD2,  0x00,  0xD2,  0xD1,  0xD1,  0xD1,  0xD1, // D
        0x10,  0xF2,  0x00,  0xF2,  0xB0,  0xB0,  0xB0,  0xB0, // E
        0x01,  0x10,  0x01,  0x00,  0xD0,  0xD0,  0xD0,  0xD0, // E
        0xC0,  0xF1,  0x00,  0xF1,  0xB1,  0xB1,  0xB1,  0xB1, // F
        0x01,  0xD2,  0x00,  0xD2,  0xD1,  0xD1,  0xD1,  0xD1 ]; // F
}
