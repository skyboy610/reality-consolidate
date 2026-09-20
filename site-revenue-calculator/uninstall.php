<?php
defined( 'WP_UNINSTALL_PLUGIN' ) || exit;

delete_option( 'srevc_settings' );
delete_transient( 'srevc_last_report' );

if ( is_multisite() ) {
	$sites = get_sites( array( 'fields' => 'ids' ) );
	foreach ( $sites as $site_id ) {
		switch_to_blog( $site_id );
		delete_option( 'srevc_settings' );
		delete_transient( 'srevc_last_report' );
		restore_current_blog();
	}
}
