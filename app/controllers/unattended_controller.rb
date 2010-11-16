class UnattendedController < ApplicationController
  layout nil
  before_filter :get_host_details, :allowed_to_install?, :except => [:pxe_kickstart_config, :pxe_debian_config]
  before_filter :handle_ca, :except => [:jumpstart_finish, :preseed_finish, :pxe_kickstart_config, :gpxe_kickstart_config, :pxe_debian_config]
  skip_before_filter :require_ssl, :require_login, :authorize, :load_tabs, :manage_tabs
  after_filter :set_content_type, :only => [:kickstart, :preseed, :preseed_finish,
    :jumpstart_profile, :jumpstart_finish, :pxe_kickstart_config, :gpxe_kickstart_config, :pxe_debian_config]
  before_filter :set_admin_user, :only => :built

  def kickstart
    @dynamic   = @host.diskLayout =~ /^#Dynamic/
    @arch      = @host.architecture.name
    os         = @host.operatingsystem
    @osver     = os.major.to_i
    @mediapath = os.mediapath @host
    @epel      = os.epel      @host
    @yumrepo   = os.yumrepo   @host

    # force static network configurtion if static http parameter is defined, in the future this needs to go into the GUI
    @static = !params[:static].empty?
    unattended_local "kickstart"
  end

  def jumpstart_profile
    unattended_local "jumpstart_profile"
  end

  def jumpstart_finish
    unattended_local "jumpstart_finish"
  end

  def preseed
    @preseed_path   = @host.os.preseed_path   @host
    @preseed_server = @host.os.preseed_server @host
    unattended_local "preseed"
  end

  def preseed_finish
    unattended_local "preseed_finish"
  end

  # this actions is called by each operatingsystem post/finish script - it notify us that the OS installation is done.
  def built
    logger.info "#{controller_name}: #{@host.name} is Built!"
    head(@host.built ? :created : :conflict)
  end

  def pxe_kickstart_config
    @host = Host.find_by_name params[:host_id]
    prefix = @host.operatingsystem.pxe_prefix(@host.arch)
    @kernel = "#{prefix}-#{Redhat::PXEFILES[:kernel]}"
    @initrd = "#{prefix}-#{Redhat::PXEFILES[:initrd]}"
  end

  # Returns a valid GPXE config file to kickstart hosts
  def gpxe_kickstart_config
  end

  def pxe_debian_config
    @host = Host.find_by_name params[:host_id]
    prefix = @host.operatingsystem.pxe_prefix(@host.arch)
    @kernel = "#{prefix}-#{Debian::PXEFILES[:kernel]}"
    @initrd = "#{prefix}-#{Debian::PXEFILES[:initrd]}"
  end

  private
  # lookup for a host based on the ip address and if possible by a mac address(as sent by anaconda)
  # if the host was found than its record will be in @host
  # if the host doesn't exists, it will return 404 and the requested method will not be reached.

  def get_host_details
    # find out ip info
    if params.has_key? "spoof"
      ip = params.delete("spoof")
      @spoof = true
    elsif (ip = request.env['REMOTE_ADDR']) =~ /127.0.0/
      ip = request.env["HTTP_X_FORWARDED_FOR"] unless request.env["HTTP_X_FORWARDED_FOR"].nil?
    end

    # search for a mac address in any of the RHN provsioning headers
    # this section is kickstart only relevant
    maclist = []
    unless request.env['HTTP_X_RHN_PROVISIONING_MAC_0'].nil?
      begin
        request.env.keys.each do | header |
          maclist << request.env[header].split[1].downcase.strip if header =~ /^HTTP_X_RHN_PROVISIONING_MAC_/
        end
      rescue => e
        logger.info "unknown RHN_PROVISIONING header #{e}"
      end
    end

    # we try to match first based on the MAC, falling back to the IP
    conditions = (!maclist.empty? ? {:mac => maclist} : {:ip => ip})
    @host = Host.find(:first, :include => [:architecture, :media, :operatingsystem, :domain], :conditions => conditions)
    unless @host
      logger.info "#{controller_name}: unable to find ip/mac match for #{ip}"
      head(:not_found) and return
    end
    unless @host.operatingsystem
      logger.error "#{controller_name}: #{@host.name}'s operatingsystem is missing!"
      head(:conflict) and return
    end
    unless @host.operatingsystem.family
      # Then, for some reason, the OS has not been specialized into a Redhat or Debian class
      logger.error "#{controller_name}: #{@host.name}'s operatingsytem [#{@host.operatingsystem.fullname}] has no OS family!"
      head(:conflict) and return
    end
    logger.info "Found #{@host}"
  end

  def allowed_to_install?
    (@host.build or @spoof) ? true : head(:method_not_allowed)
  end

  # Cleans Certificate and enable autosign
  def handle_ca
    #the reason we do it here is to minimize the amount of time it is possible to automatically get a certificate
    #through puppet.

    # we don't do anything if we are in spoof mode.
    return if @spoof

    return false unless GW::Puppetca.clean @host.name
    return false unless GW::Puppetca.sign @host.name
  end

  def unattended_local type
    render :template => "unattended/#{type}.local" if File.exists?("#{RAILS_ROOT}/app/views/unattended/#{type}.local.rhtml")
  end

  def set_content_type
    response.headers['Content-Type'] = 'text/plain'
  end

end
