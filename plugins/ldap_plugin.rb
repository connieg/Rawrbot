# =============================================================================
# Plugin: LDAPsearch
#
# Description:
# 	Searches LDAP for an account (!ldap) or a person's phone number (!phone), 
# 	and returns results about that query, if found.
#
# Requirements:
#		- The Ruby gem NET-LDAP.
#		- Authentication information for NET-LDAP in the file 'auth_ldap.rb'.
#			The file must define a function named return_ldap_config which returns a
#			hash with two key->value pairs 'username' and 'pass', which rawrbot
#			will use to bind with OIT LDAP.
#		- Rawrbot must be running on PSU's IP space (131.252.x.x). OIT's
# 		authenticated LDAP directory (what rawrbot uses in this module) is
# 		inaccessible otherwise.
class LDAPsearch
	include Cinch::Plugin
	
	self.prefix = lambda{ |m| /^#{m.bot.nick}/ }

	require 'net/ldap'

	match(/^!help ldap/i, :use_prefix => false, method: :ldap_help)
	match(/^!help phone/i, :use_prefix => false, method: :phone_help)
	match("!help", :use_prefix => false, method: :help)
	match(/^!ldap (\S+)/i, :use_prefix => false)
	# The next line was helped out by:
	# http://stackoverflow.com/questions/406230/regular-expression-to-match-string-not-containing-a-word
	# This is meant to make rawrbot not trigger this module when someone attempts
	# to teach it about ldap with the learning module.
	match(/[:-]? ldap (((?!(.+)?is ).)+)/i)
	match(/^!phone (.+)/i, :use_prefix => false, method: :phone_search)

	# Function: execute
	#
	# Description: Parses the search query and executes a search on LDAP to retrieve
	# account information. Automatically decides what field of LDAP to search based
	# on what the query looks like. It then prints the results to the IRC user who
	# made the request.
	def execute(m, query)
		
		reply = String.new()
		
		# Error-checking to sanitize input. i.e. no illegal symbols.
		if (query =~ /[^\w@._-]/)
			m.reply("Invalid search query '#{query}'")
			return
		end	

		query.downcase!
		
		# Determine what field to search and proceed to execute it.
		if (query =~ /@pdx\.edu/)
			type = 'email alias'
			attribute = 'mailLocalAddress'
		else
			type = 'username'
			attribute = 'uid'
		end
		m.reply("Performing LDAP search on #{type} #{query}.")
		
		search_result = ldap_search(attribute,query)
		
		if (!search_result)
			m.reply "Error: LDAP query failed. Check configuration."
		else
			#	Piece together the final results and print them out in user-friendly output.
			if (search_result['dn'].empty?)
				reply = "Error: No results.\n"
			elsif (search_result['dn'].length > 1)
				# Realistically this case should never happen because we filtered '*'
				# out of the search string earlier. If this comes up, something in LDAP
				# is really janky. The logic to account for this is here nonetheless,
				# just in case.
				reply = "Error: Too many results.\n"
			else
				#	Get name, username and dept of the user.
				search_result['gecos'].each { |name| reply << "Name: #{name}\n" }
				search_result['uid'].each { |uid| reply << "Username: #{uid}\n" }
				search_result['ou'].each { |dept| reply << "Dept: #{dept}\n" }
				
				# Determine if this is a sponsored account, and if so, who the sponsor is.
				if (search_result['psusponsorpidm'].empty?)
					reply << "Sponsored: no\n"
				else
					# Look up sponsor's information.
					reply << "Sponsored: yes\n"
					sponsor_uniqueid = search_result['psusponsorpidm'][0]
					# Fix some malformed psusponsorpidms.
					if (!(sponsor_uniqueid =~ /^P/i))
						sponsor_uniqueid = "P" + sponsor_uniqueid
					end
					
					ldap_sponsor_entry = ldap_search("uniqueIdentifier",sponsor_uniqueid)
				
					sponsor_name = ldap_sponsor_entry['gecos'][0]
					sponsor_uid = ldap_sponsor_entry['uid'][0]
					reply << "Sponsor: #{sponsor_name} (#{sponsor_uid})\n"
				end
			
				# Determine the account and password expiration dates. Also, estimate the date the
				# password was originally set by subtracting 6 months from the expiration date.
				search_result['psuaccountexpiredate'].each do |acctexpiration|
					acct_expire_date = parse_date(acctexpiration)
					reply << "Account expires: #{acct_expire_date.asctime}\n"
				end
				search_result['psupasswordexpiredate'].each do |pwdexpiration|
					pwd_expire_date = parse_date(pwdexpiration)
					reply << "Password expires: #{pwd_expire_date.asctime}\n"
					# Calculate the date/time that the password was set.
					day = 86400 # seconds
					pwd_set_date = pwd_expire_date - (180 * day)
					reply << "Password was set: #{pwd_set_date.asctime}\n"
				end

				# Print out any email aliases.
				search_result['maillocaladdress'].each { |email_alias| reply << "Email alias: #{email_alias}\n" }
			end
			# Send results via PM so as to not spam the channel.
			User(m.user.nick).send(reply)
		end
	end # End of execute function.
	
	# Function: parse_date
	#
	# Description: Parses a String containing a date in Zulu time, and returns
	# it as a Time object.
	#
	# Arguments:
	# - A String, containing a date/time in Zulu time:
	#   yyyymmddhhmmssZ
	#
	# Returns:
	# - An instance of class Time, containing the date and time.
	def parse_date date
		unless date =~ /(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z/
			return nil
		end
		
		year = $1
		month = $2
		day = $3
		hour = $4
		min = $5
		sec = $6

		return Time.mktime(year, month, day, hour, min, sec)
	end # End of parse_date function.
	
	def ldap_search(attr,query)
		load "#{$pwd}/plugins/config/ldap_config.rb"
	
		# ldap_return auth (below) is a function from auth_ldap.rb that returns a
		# hash with the username and password to bind to LDAP with.
		ldap_config = return_ldap_config()

		host = ldap_config[:server]
		port = ldap_config[:port]
 		auth = { :method => :simple, :username => ldap_config[:username], :password => ldap_config[:pass] }
		base = ldap_config[:basedn]
	
		result = Hash.new(Array.new())
		Net::LDAP.open(:host => host, :port => port, :auth => auth, :encryption => :simple_tls, :base => base) do |ldap|
			
			# Perform the search, then return a hash with LDAP attributes corresponding
			# to hash keys, and LDAP values corresponding to hash values.
			filter = Net::LDAP::Filter.eq(attr,query)
			if ldap.bind()
				ldap.search(:filter => filter) do |entry|
					entry.each do |attribute, values|
						values.each do |value|
							result["#{attribute}"] += ["#{value}"]
						end
					end
				end
			else
				result = false
			end
		end

		return result
	end # End of ldap_search function

	# Function: phone_search
	#
	# Description: Executes a search on LDAP for a person's username or email address to
	# retrieve a phone number. It then prints the results to the channel where the IRC
	# user made the request.
	def phone_search(m, query)

		# Error-checking to sanitize input. i.e. no illegal symbols.
		if (query =~ /[^\w@._-]/)
			m.reply("Invalid search query '#{query}'")
			return
		end	
		query.downcase!

		# Determine what field to search and proceed to execute it.
		if (query =~ /@pdx\.edu/)
			attribute = 'mailLocalAddress'
		else
			attribute = 'uid'
		end
		
		search_result = ldap_search(attribute,query)
		reply = String.new()
		
		if (!search_result)
			reply = "Error: LDAP query failed. Check configuration."
		else
			#	Piece together the final results and print them out in user-friendly output.
			if (search_result['dn'].empty?)
				reply = "No results for #{query}.\n"
			elsif (search_result['telephonenumber'].empty?)
				reply = "No results for #{query}.\n"
			elsif (search_result['dn'].length > 1)
				# Realistically this case should never happen because we filtered '*'
				# out of the search string earlier. If this comes up, something in LDAP
				# is really janky. The logic to account for this is here nonetheless,
				# just in case.
				reply = "Error: Too many results.\n"
			else
				#	Get name and phone of the user.
				search_result['gecos'].each { |name| reply << "Name: #{name}\n" }
				search_result['telephonenumber'].each { |phone| reply << "Phone: #{phone}\n" }
			end
		end

		m.reply(reply)
		return
	end # End of phone_search function.

	def ldap_help(m)
		m.reply("LDAP Search")
		m.reply("===========")
		m.reply("Description: Performs a search on LDAP for the given query, then returns information about the user's account.")
		m.reply("Usage: !ldap [username|email alias]")
	end # End of ldap_help function.
	
	def phone_help(m)
		m.reply("Phone Search")
		m.reply("===========")
		m.reply("Description: Searches LDAP for the given query, then returns the user's phone number, if it exists in LDAP.")
		m.reply("Usage: !phone [username|email alias]")
	end # End of phone_help function.

	def help(m)
		m.reply("See: !help ldap")
		m.reply("See: !help phone")
	end # End of help function.

end
# End of plugin: LDAPsearch
# =============================================================================
