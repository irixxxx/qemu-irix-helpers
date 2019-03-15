#! /usr/bin/ruby

# minimalistic SGI inst clone
# - (un)installs files from tardist idb/archive files to target filesystem
# - no dependency tracking, no history, no hinv, no pre/post/exit/removeop, ...
# (C) 2008 Kai-Uwe Bloem

# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, see <http://www.gnu.org/licenses/>.

class UGId
    # read the IRIX user/group database from the target root
    def initialize(path)
	@users = { }   # user names and the associated uid
	@groups = { }  # group names and the associated gid
	begin
	    IO.foreach(path + "/etc/passwd") do |u|
		tokens = u.split(":")
		@users[tokens[0]] = tokens[2].to_i
	    end
	    IO.foreach(path + "/etc/group") do |g|
		tokens = g.split(":")
		@groups[tokens[0]] = tokens[2].to_i
	    end
	rescue  # no real harm done if we can't get IDs, but inform the user
	    puts "WARNING: can't read uid/gid database from target filesystem"
	    @users["root"] = 0
	    @groups["root"] = 0
	end
    end

    # returns an array of [uid, gid] for the given user and group
    def names2ids(uname, gname)
	[ @users[uname], @groups[gname] ]
    end
end

module Mach
    @taglist = { }	# tags and their values used in the mach() expressions
    @tagmiss = { }	# tags for which no value was given with -m

    # parser for IDB "mach(...)" tokens
    # TODO: nesting with "()" isn't supported yet
    #
    # tree entries: expressions, or'ed: tree[0] || tree[1]...
    # expression entries: operations, and'ed: expr[0] && expr[1]...
    # operations: [tag op [val...]], op is either:
    #	:eq (tag == val[0] || tag == val[1] ||...) or
    #	:ne (tag != val[0] && tag != val[1] &&...)
    #
    # X=O X=P... -> [ [ [:X :eq [:O :P]] ] ]
    # X!=O, !X=O -> [ [ [:X :ne [:O]] ] ]
    # X=O Y=P... -> [ [ [:X :eq [:O]] [:Y :eq [:P]] ] ]
    # X=O Y=P Z=Q Y=R -> [ [ [:X :eq [:O]] [:Y :eq [:P]] [:Z :eq [:Q]] ]
    #			[ [:X :eq [:O]] [:Y :eq [:R]] ] ]
    # X==O && Y==P -> [ [ [:X :eq [:O]] [:Y :eq [:P]] ] ]
    # X==O || Y==P -> [ [ [:X :eq [:O]] ] [ [:Y :eq [:P]] ] ]

    # parse mach(...) specification.
    # TODO not really a parser. rewrite this.
    def Mach::parse(line)
	tree = [ ]
	expr = [ ]
	old = true	# old format?
	line.gsub(/(\|\|)|(&&)/, " \1 ").split(" ").each do |atom|
	    # parse: !nteq=nveq, tne!=vne, teq=veq, ||, &&, tag
	    atom.scan(/!([[:graph:]]+)=([[:graph:]]*)|
			([[:graph:]]+)!=([[:graph:]]*)|
			([[:graph:]]+)=([[:graph:]]*)|
			(\|\|)|(&&)|
			([[:graph:]]+)
			/x) do |nteq,nveq,tne,vne,teq,veq,oor,oand,tag|
		teq, veq = "CPUBOARD", tag if tag	# IPxx => CPUBOARD=IPxx
		tne, vne = nteq, nveq	   if nteq	# !X=O => X!=O
		if tne || teq				# comparison !=,= ?
		    tag, op, val = tne.to_sym, :ne, vne.to_sym if tne
		    tag, op, val = teq.to_sym, :eq, veq.to_sym if teq
		    if old && expr.length > 0
			# X=O X=P ... => X=[O,P], denoting (X=O || X=P ...)
			if expr[-1][0] == tag && expr[-1][1] == :eq && op == :eq
			    expr[-1][2] << val
			    op = nil		# no new comparison entry
			# X=O Y=P Z=Q Y=R => (X=O && Y=P && Z=Q) || (X=O && Y=R)
			elsif pop = expr.rindex { |o| o[0] == tag }
			    tree << expr
			    expr = expr.take(pop)
			end
		    end
		    expr << [ tag, op, [ val ] ] if op	# add comparison entry
		    @taglist[tag] = { } unless @taglist[tag]
		    @taglist[tag][val] = nil
		elsif oor			# || => start new "and" expr
		    tree << expr
		    expr = [ ]
		end
		old = false if oand || oor	# &&, || => no old X=O Y=P form
	    end
	end
	tree << expr if expr.length > 0
	return tree
    end

    # match mach(...) with user parameters. returns true if match
    def Mach::match(line, match)
	return true if ! line
	tree = parse(line)
	tree.each do |expr|			# for each "or" expression
	    result = true
	    expr.each do |op|			# for each "and" operation
		term = nil
		match.each do |m|		# for each -m value
		    tag, val = m.split("=").map { |s| s.to_sym }
		    term = op[2].include? val if op[0] == tag
		end
		if term == nil && ! @tagmiss[op[0]] then
		    puts "WARNING: missing machine value for #{op[0]}"
		    @tagmiss[op[0]] = true
		end
		result = result &&  term if op[1] == :eq
		result = result && !term if op[1] == :ne
	    end
	    return true if result
	end
	return false
    end

    # for tags not given by -m, output values encountered in parsed mach data
    def Mach::missing
	@tagmiss.each_key do |tag|
	    list = @taglist[tag] ? @taglist[tag].each_key.to_a : []
	    puts "values in idb file for #{tag}: #{list.join(",")}"
	end
    end
end

class Idb
    # parse the idb file
    def initialize(file)
	@entries = [ ]	# entries as array to keep the sequence
	@sublist = { }	# subsystem names found in idb file
	@toklist = { }	# tokens found in idb file

	IO.foreach(file) do |line|
	    # the first 6 tokens have a fixed meaning
	    tokens = line.split(" ",7)
	    next if ! tokens[4] # tape files may end with a sequence of '\0'
	    entry = { :type => tokens[0], :mode => tokens[1],
			:owner => tokens[2], :group => tokens[3],
			:path => tokens[4], :unknown => tokens[5] }
	    # split and assign the rest: either ts("s"), tq('q'), tv(v) or t
	    tokens[6].scan(/([[:graph:]]+)\(\"([^\"]+)\"\)|
			    ([[:graph:]]+)\(\'([^\']+)\'\)|
			    ([[:graph:]]+)\(([^\)]+)\)|
			    ([[:graph:]]+)
			    /x) do |ts,s,tq,q,tv,v,t|
		if t && t.include?(".") then
		    # valueless tag with dots, most probably subsystem name
		    entry[:subsystem] = t
		else
		    # some tokens have a value (number or string), others not
		    sym, val = t.to_sym, "" if t
		    sym, val = tv.to_sym, v if tv
		    sym, val = ts.to_sym, s if ts
		    sym, val = tq.to_sym, q if tq
		    entry[sym] = val
		    @toklist[sym] = { } unless @toklist[sym]
		    @toklist[sym][val.to_sym] = nil
		end
	    end
	    @sublist[entry[:subsystem]] = nil
	    @entries << entry if ! entry[:delhist]  # "completely ignored"
	end
    end

    attr_accessor :ugids, :verbose, :execute

    # data length of entry, either compressed or uncompressed
    def _length(entry)
	len = entry[:cmpsize].to_i
	len = entry[:size].to_i if len == 0
	return len
    end

    # bind the 1st unused entry for this name to its archive position
    def setdata(name, arc, pos)
	@entries.each { |e|
	    if e[:path] == name && e[:size] && ! e[:_archive] && (
			e[:subsystem].start_with?(arc.name) || arc.name.start_with?(e[:subsystem].gsub(/\..*$/, '')) ||
			e[:unknown].start_with?(arc.name) || arc.name.start_with?(e[:unknown].gsub(/\..*$/, '')))
		e[:_archive] = arc
		e[:_position] = pos
		return _length(e)
	    end
	}
	puts "ERROR: no idb entry for #{name}"
	return nil
    end

    # "execute" the command (for now, cowardly just output it...)
    def _execute(cmd, path)
	# system("export rbase=#{path}/;export vhdev=/tmp/vhdev;export mr=true;"
	#    + "export diskless=none;export instmode=normal;export nl=1;"
	#    + cmd) if cmd && @execute
	puts cmd if cmd && @execute
    end

    # install entry to the target filesystem
    def _extract(entry, path)
	name = path + "/" + entry[:path]
	puts "extracting #{name}" if @verbose

	# create directory for file if it doesn't yet exist
	dir = name.gsub(/\/[^\/]*$/,"")
	system("mkdir -p #{dir}") if ! FileTest.exist?(dir)
	begin File.chmod(0755, dir); rescue; end

	# find origin for hardlinks if requested
	ref = nil
	if entry[:f] then
	    @entries.each { |e| ref = e if e[:f] == entry[:f] && e[:_written] }
	end

	_execute(entry[:preop], path)
	begin File.unlink(name); rescue; end if entry[:type] != "d"
	# action depending on entry type
	if entry[:type] == "d"
	    begin Dir.mkdir(name) if ! FileTest.directory?(name)
		rescue; puts "WARNING: can't create directory #{name}"
	    end
	elsif entry[:type] == "l"
	    File.symlink(entry[:symval], name)
	elsif entry[:type] == "X"
	    # begin File.unlink(name); rescue; end	already done above
	elsif ref then
	    oldname = path + "/" + ref[:path]
	    begin File.link(oldname, name)
		rescue; puts "WARNING: can't link #{name} to #{oldname}"
	    end
	elsif entry[:cmpsize].to_i != 0 && entry[:_archive]
	    data = entry[:_archive].getdata(entry[:_position], _length(entry)) 
	    IO.popen("gzip -cd > #{name}", "w") { |f| f.write(data) }
	elsif entry[:_archive]
	    data = entry[:_archive].getdata(entry[:_position], _length(entry))
	    File.open(name, "w") { |f| f.write(data) }
	else
	    puts "WARNING: no archive data for #{name} (type #{entry[:type]})"
	end
	_execute(entry[:postop], path)
	entry[:_written] = true
    end

    # set file attributes in target fs, but not for links or deleted files
    def _attributes(entry, path)
	if entry[:type] != "l" && entry[:type] != "X"
	    name = path + "/" + entry[:path]
	    begin File.chmod(entry[:mode].to_i(8), name)
		rescue; puts "WARNING: can't change mode for #{name}"
	    end
	    uid, gid  = @ugids.names2ids(entry[:owner], entry[:group])
	    begin File.chown(uid, gid, name) if uid && gid && Process.euid == 0
		rescue; puts "WARNING: can't change owner for #{name}"
	    end
	end
    end

    # uninstall entry from the target filesystem
    def _remove(entry, path)
	name = path + "/" + entry[:path]
	puts "removing #{name}" if @verbose
	_execute(entry[:removeop], path)
	begin entry[:type] == "d" ? Dir.rmdir(name) : File.unlink(name)
	    rescue; puts "WARNING: could not remove #{name}"
	end
    end

    # return true if entry matches subsystem and -m definitions given by user
    def _match(entry, subsys, mach)
	entry[:subsystem].match("^#{subsys}") && Mach::match(entry[:mach], mach)
    end

    def subsystems
	@sublist.each_key.to_a
    end

    def tokens
	@toklist.each_key.to_a
    end

    def values(token)
	@toklist[token.to_sym] ? @toklist[token.to_sym].each_key.to_a : []
    end

    def files(subsys, mach)
	list = []
	@entries.each { |e| list << e[:path] if _match(e, subsys, mach) }
	list
    end

    def install(subsys, path, mach)
	puts "WARNING: not root, not chown'ing files" if Process.euid != 0
	@entries.each { |e| _extract(e, path) if _match(e, subsys, mach) }
	@entries.each { |e| _attributes(e, path) if _match(e, subsys, mach) }
	@entries.each { |e| _execute(e[:exitop], path) if _match(e, subsys, mach) }
    end

    def uninst(subsys, path, mach)
	@entries.reverse.each { |e| _remove(e, path) if _match(e, subsys, mach) }
    end
end

class Archive
    # parse the archive file
    def initialize(file, idb)
	@idb = idb
	@name = File.basename(file)
	begin @fd = File.open(file)
	    rescue; puts "WARNING: can't open archive #{file}"; return nil
	end

	# read the header
	c = ""
	@fd.read(1,c) while c.getbyte(0) != 0
	@fd.pos = 0 if @fd.pos < 2 # old style without header

	# process entries in archive
	while ! @fd.eof do
	    _processone
	end
    end

    # read next filename from archive
    def _readname
	len = 0;
	@fd.read(2).each_byte { |c| len = (len << 8) + c }
	@fd.read(len)
    end

    # return subsystem base this archive belongs to
    def name
	return @name
    end

    # return data from the archive
    def getdata(pos, len)
	@fd.pos = pos
	@fd.read(len)
    end

    # read the next name from the archive
    def _processone
	name = _readname
	# add the file to the database and advance the file position
	@fd.pos += @idb.setdata(name, self, @fd.pos) if name.length > 0
    end
end

def usage(code)
    puts "error: #{code}"
    puts "usage: inst [sfciu] <package> [-r<extraction path>] [-s<subsystem pattern>]* [-m<machine tag>=<value>]* -x -v"
    puts "	s: list subsystems; f: list files; c: check -m parameters; i, u: (un)install"
    puts "	-r: install base; -s: subsystem; -m: machine tags; -v: verbose"
    puts "	-x: print pre/post/exit/remove commands"
    puts "known -m tags for CPU: CPUBOARD=IPn, CPUARCH=Rn000, MODE={32|64}bit"
    puts "known -m tags for GFX: GFXBOARD=name, SUBGR=name, VIDEO=name"
    puts "see /usr/var/inst/machfile for valid values and combinations"
    Process.exit(1)
end

if ARGV.length >= 2 && FileTest.readable?(ARGV[1] + ".idb")
    # open and read idb database and the archives
    idb = Idb.new(ARGV[1] + ".idb")
    Dir.glob(ARGV[1] + ".*").each { |f|
	Archive.new(f, idb) unless f =~ /\.idb$/
    }
else
    usage("cannot open idb file")
end

# parse options
root = "/"
subsys=[]
mach = []
token = nil
idb.execute = nil
idb.verbose = nil
ARGV[2..-1].each { |a|
    case a[0..1]
    when "-r"
	root = a[2..-1]
    when "-s"
	subsys << a[2..-1]
    when "-m"
	mach << a[2..-1]
    when "-t"
	token = a[2..-1]
    when "-x"
	idb.execute = true
    when "-v"
	idb.verbose = true
    else
	usage("unknown argument " + a)
    end
}
# match all subsystems if none was given
subsys << ".*" if subsys.empty?

idb.ugids = UGId.new(root)

# execute operation
case ARGV[0]
when "s"	# list subsystems
    puts "#{idb.subsystems.join("\n")}"
when "c"	# parameter check
    subsys.each { |s| idb.files('\A'+s+'\Z', mach) }; Mach::missing()
when "f"	# list files in subsystems
    subsys.each { |s| puts "#{idb.files('\A'+s+'\Z', mach).join("\n")}" }
when "i"	# install subsystems
    subsys.each { |s| idb.install('\A'+s+'\Z', root, mach) }
when "u"	# uninstall subsystems
    subsys.each { |s| idb.uninst('\A'+s+'\Z', root, mach) }
when "t"	# DEBUG: list tokens found in idb files
    puts "#{idb.tokens.join("\n")}"
when "v"	# DEBUG: list values found for given token
    puts "#{idb.values(token).join("\n")}"
else
    usage("unkown command" + ARGV[0])
end
