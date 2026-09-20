<?php
defined( 'ABSPATH' ) || exit;

class Srevc_Admin {

	const PAGE_REPORT   = 'srevc-report';
	const PAGE_SETTINGS = 'srevc-settings';

	public static function init() {
		add_action( 'admin_menu', array( __CLASS__, 'menu' ) );
		add_action( 'admin_enqueue_scripts', array( __CLASS__, 'assets' ) );
		add_action( 'admin_post_srevc_export', array( __CLASS__, 'export_csv' ) );
	}

	public static function menu() {
		if ( ! srevc_woocommerce_active() ) {
			return;
		}

		add_menu_page(
			__( 'محاسبه درآمد سایت', 'site-revenue-calculator' ),
			__( 'محاسبه درآمد', 'site-revenue-calculator' ),
			SREVC_CAPABILITY,
			self::PAGE_REPORT,
			array( __CLASS__, 'render_report' ),
			'dashicons-chart-area',
			56
		);

		add_submenu_page(
			self::PAGE_REPORT,
			__( 'گزارش درآمد', 'site-revenue-calculator' ),
			__( 'گزارش درآمد', 'site-revenue-calculator' ),
			SREVC_CAPABILITY,
			self::PAGE_REPORT,
			array( __CLASS__, 'render_report' )
		);

		add_submenu_page(
			self::PAGE_REPORT,
			__( 'تنظیمات', 'site-revenue-calculator' ),
			__( 'تنظیمات', 'site-revenue-calculator' ),
			SREVC_CAPABILITY,
			self::PAGE_SETTINGS,
			array( 'Srevc_Settings', 'render' )
		);
	}

	public static function assets( $hook ) {
		if ( false === strpos( (string) $hook, self::PAGE_REPORT ) && false === strpos( (string) $hook, self::PAGE_SETTINGS ) ) {
			return;
		}

		wp_enqueue_style( 'srevc-admin', SREVC_URL . 'assets/css/admin.css', array(), SREVC_VERSION );
		wp_enqueue_script( 'srevc-admin', SREVC_URL . 'assets/js/admin.js', array(), SREVC_VERSION, true );

		$today = Srevc_Jalali::today();
		wp_localize_script(
			'srevc-admin',
			'srevcData',
			array(
				'today'      => array(
					'jy' => $today[0],
					'jm' => $today[1],
					'jd' => $today[2],
				),
				'months'     => array_values( Srevc_Jalali::month_names() ),
				'weekdays'   => array( 'ش', 'ی', 'د', 'س', 'چ', 'پ', 'ج' ),
				'todayLabel' => __( 'امروز', 'site-revenue-calculator' ),
				'clearLabel' => __( 'پاک کردن', 'site-revenue-calculator' ),
			)
		);
	}

	public static function render_header( $title ) {
		?>
		<div class="srevc-banner">
			<div class="srevc-banner-logo">
				<pre class="srevc-ascii">
 ____  _____ _     _ _____ _   _ _   _ _____
|  _ \| ____| |   | | ____| \ | | | | | ____|
| |_) |  _| | |   | |  _| |  \| | | | |  _|
|  _ <| |___|  \_/  | |___| |\  | |_| | |___
|_| \_\_____|\_____/|_____|_| \_|\___/|_____|
				</pre>
			</div>
			<div class="srevc-banner-text">
				<h1><?php echo esc_html( $title ); ?></h1>
				<span class="srevc-banner-sub"><?php echo esc_html( sprintf( 'Site Revenue Calculator v%s', SREVC_VERSION ) ); ?></span>
			</div>
		</div>
		<?php
	}

	protected static function current_request() {
		$settings = srevc_get_settings();

		$preset = isset( $_GET['srevc_range'] ) ? sanitize_key( wp_unslash( $_GET['srevc_range'] ) ) : $settings['default_range'];
		if ( ! array_key_exists( $preset, Srevc_Range::presets() ) ) {
			$preset = $settings['default_range'];
		}

		$start = isset( $_GET['srevc_start'] ) ? sanitize_text_field( wp_unslash( $_GET['srevc_start'] ) ) : '';
		$end   = isset( $_GET['srevc_end'] ) ? sanitize_text_field( wp_unslash( $_GET['srevc_end'] ) ) : '';

		$statuses = array();
		if ( isset( $_GET['srevc_status'] ) && is_array( $_GET['srevc_status'] ) ) {
			$statuses = array_map( 'sanitize_text_field', wp_unslash( $_GET['srevc_status'] ) );
			$statuses = array_values( array_intersect( $statuses, array_keys( Srevc_Query::available_statuses() ) ) );
		}
		if ( empty( $statuses ) ) {
			$statuses = (array) $settings['statuses'];
		}

		return array(
			'preset'   => $preset,
			'start'    => $start,
			'end'      => $end,
			'statuses' => $statuses,
			'settings' => $settings,
		);
	}

	protected static function build_report( $request ) {
		$range = Srevc_Range::resolve( $request['preset'], $request['start'], $request['end'] );
		if ( is_wp_error( $range ) ) {
			return $range;
		}

		$settings = $request['settings'];

		return Srevc_Query::run(
			array(
				'start'                  => $range['start'],
				'end'                    => $range['end'],
				'statuses'               => $request['statuses'],
				'exclude_via'            => (array) $settings['exclude_via'],
				'exclude_zero'           => ! empty( $settings['exclude_zero'] ),
				'wallet_keywords'        => Srevc_Query::split_list( $settings['wallet_keywords'] ),
				'wallet_products'        => Srevc_Query::split_list( $settings['wallet_products'] ),
				'wallet_gateways'        => Srevc_Query::split_list( $settings['wallet_gateways'] ),
				'exclude_wallet_payment' => ! empty( $settings['exclude_wallet_payment'] ),
			)
		);
	}

	public static function render_report() {
		if ( ! srevc_user_can() ) {
			wp_die( esc_html__( 'شما دسترسی لازم برای مشاهده این صفحه را ندارید.', 'site-revenue-calculator' ) );
		}

		$request  = self::current_request();
		$settings = $request['settings'];
		$report   = self::build_report( $request );
		$presets  = Srevc_Range::presets();
		$statuses = Srevc_Query::available_statuses();

		$start_value = $request['start'];
		$end_value   = $request['end'];
		if ( ! is_wp_error( $report ) ) {
			$start_value = Srevc_Jalali::format_gregorian_string( $report['start'] );
			$end_value   = Srevc_Jalali::format_gregorian_string( $report['end'] );
		}
		?>
		<div class="wrap srevc-wrap" dir="rtl">
			<?php self::render_header( 'گزارش درآمد سایت' ); ?>

			<form method="get" class="srevc-card srevc-filters">
				<input type="hidden" name="page" value="<?php echo esc_attr( self::PAGE_REPORT ); ?>" />

				<div class="srevc-presets">
					<?php
					$index = 0;
					foreach ( $presets as $key => $label ) :
						$index++;
						?>
						<label class="srevc-chip srevc-chip-<?php echo esc_attr( $index ); ?> <?php echo ( $key === $request['preset'] ) ? 'is-active' : ''; ?>">
							<input type="radio" name="srevc_range" value="<?php echo esc_attr( $key ); ?>" <?php checked( $key, $request['preset'] ); ?> />
							<span><?php echo esc_html( $label ); ?></span>
						</label>
					<?php endforeach; ?>
				</div>

				<div class="srevc-filter-row">
					<div class="srevc-field">
						<label class="srevc-label-blue" for="srevc-start"><?php esc_html_e( 'از تاریخ', 'site-revenue-calculator' ); ?></label>
						<input type="text" id="srevc-start" name="srevc_start" value="<?php echo esc_attr( $start_value ); ?>" data-srevc-jalali="1" autocomplete="off" placeholder="۱۴۰۴/۰۱/۰۱" />
					</div>
					<div class="srevc-field">
						<label class="srevc-label-purple" for="srevc-end"><?php esc_html_e( 'تا تاریخ', 'site-revenue-calculator' ); ?></label>
						<input type="text" id="srevc-end" name="srevc_end" value="<?php echo esc_attr( $end_value ); ?>" data-srevc-jalali="1" autocomplete="off" placeholder="۱۴۰۴/۰۱/۳۱" />
					</div>
					<div class="srevc-field srevc-field-status">
						<span class="srevc-label-teal"><?php esc_html_e( 'وضعیت سفارش', 'site-revenue-calculator' ); ?></span>
						<div class="srevc-status-grid">
							<?php foreach ( $statuses as $key => $label ) : ?>
								<label class="srevc-status-chip">
									<input type="checkbox" name="srevc_status[]" value="<?php echo esc_attr( $key ); ?>" <?php checked( in_array( $key, (array) $request['statuses'], true ) ); ?> />
									<span><?php echo esc_html( $label ); ?></span>
								</label>
							<?php endforeach; ?>
						</div>
					</div>
					<div class="srevc-field srevc-field-actions">
						<button type="submit" class="srevc-btn srevc-btn-green"><?php esc_html_e( 'محاسبه کن', 'site-revenue-calculator' ); ?></button>
						<?php if ( ! is_wp_error( $report ) && $report['count'] > 0 ) : ?>
							<?php
							$export_url = wp_nonce_url(
								add_query_arg(
									array(
										'action'       => 'srevc_export',
										'srevc_range'  => $request['preset'],
										'srevc_start'  => $start_value,
										'srevc_end'    => $end_value,
										'srevc_status' => $request['statuses'],
									),
									admin_url( 'admin-post.php' )
								),
								'srevc_export'
							);
							?>
							<a class="srevc-btn srevc-btn-blue" href="<?php echo esc_url( $export_url ); ?>"><?php esc_html_e( 'خروجی CSV', 'site-revenue-calculator' ); ?></a>
						<?php endif; ?>
					</div>
				</div>
			</form>

			<?php if ( is_wp_error( $report ) ) : ?>
				<div class="srevc-msg srevc-msg-error"><?php echo esc_html( $report->get_error_message() ); ?></div>
				</div>
				<?php
				return;
			endif;
			?>

			<?php if ( ! empty( $report['db_error'] ) ) : ?>
				<div class="srevc-msg srevc-msg-error"><?php echo esc_html( sprintf( 'خطای پایگاه داده: %s', $report['db_error'] ) ); ?></div>
			<?php endif; ?>

			<div class="srevc-msg srevc-msg-warning">
				<?php echo esc_html( sprintf( 'بازه گزارش: %s', Srevc_Range::label( $report['start'], $report['end'] ) ) ); ?>
			</div>

			<div class="srevc-total-card">
				<span class="srevc-total-title"><?php esc_html_e( 'مبلغ کل درآمد', 'site-revenue-calculator' ); ?></span>
				<span class="srevc-total-value"><?php echo esc_html( Srevc_Format::money( $report['total'], $settings ) ); ?></span>
				<span class="srevc-total-words"><?php echo esc_html( Srevc_Format::money_words( $report['total'], $settings ) ); ?></span>
			</div>

			<div class="srevc-stats">
				<div class="srevc-stat srevc-stat-green">
					<span class="srevc-stat-label"><?php esc_html_e( 'تعداد کل تراکنش‌ها', 'site-revenue-calculator' ); ?></span>
					<span class="srevc-stat-value"><?php echo esc_html( Srevc_Format::count_label( $report['count'], $settings ) ); ?></span>
				</div>
				<div class="srevc-stat srevc-stat-blue">
					<span class="srevc-stat-label"><?php esc_html_e( 'میانگین هر تراکنش', 'site-revenue-calculator' ); ?></span>
					<span class="srevc-stat-value"><?php echo esc_html( Srevc_Format::money( $report['average'], $settings ) ); ?></span>
				</div>
				<div class="srevc-stat srevc-stat-teal">
					<span class="srevc-stat-label"><?php esc_html_e( 'فروش خدمات', 'site-revenue-calculator' ); ?></span>
					<span class="srevc-stat-value"><?php echo esc_html( Srevc_Format::money( $report['sales_total'], $settings ) ); ?></span>
					<span class="srevc-stat-sub"><?php echo esc_html( sprintf( '%s تراکنش', Srevc_Format::count_label( $report['sales_count'], $settings ) ) ); ?></span>
				</div>
				<div class="srevc-stat srevc-stat-purple">
					<span class="srevc-stat-label"><?php esc_html_e( 'شارژ کیف پول', 'site-revenue-calculator' ); ?></span>
					<span class="srevc-stat-value"><?php echo esc_html( Srevc_Format::money( $report['wallet_total'], $settings ) ); ?></span>
					<span class="srevc-stat-sub"><?php echo esc_html( sprintf( '%s تراکنش', Srevc_Format::count_label( $report['wallet_count'], $settings ) ) ); ?></span>
				</div>
			</div>

			<div class="srevc-msg srevc-msg-success">
				<?php
				echo esc_html(
					sprintf(
						'حذف شده از محاسبه: %s تراکنش صفر ریال (تست رایگان) و %s تراکنش دستی مدیر.',
						Srevc_Format::count_label( $report['skipped_zero'], $settings ),
						Srevc_Format::count_label( $report['skipped_admin'], $settings )
					)
				);
				?>
				<?php if ( $report['skipped_wallet_payment'] > 0 ) : ?>
					<?php echo esc_html( sprintf( ' همچنین %s پرداخت از کیف پول نادیده گرفته شد.', Srevc_Format::count_label( $report['skipped_wallet_payment'], $settings ) ) ); ?>
				<?php endif; ?>
			</div>

			<?php if ( empty( $report['groups'] ) ) : ?>
				<div class="srevc-msg srevc-msg-error"><?php esc_html_e( 'در این بازه هیچ تراکنش قابل محاسبه‌ای یافت نشد.', 'site-revenue-calculator' ); ?></div>
			<?php else : ?>
				<table class="srevc-table widefat">
					<thead>
						<tr>
							<th class="srevc-th-1"><?php esc_html_e( 'ردیف', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-2"><?php esc_html_e( 'نوع تراکنش', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-3"><?php esc_html_e( 'مبلغ هر تراکنش', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-4"><?php esc_html_e( 'تعداد', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-5"><?php esc_html_e( 'جمع مبلغ', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-6"><?php esc_html_e( 'سهم از درآمد', 'site-revenue-calculator' ); ?></th>
						</tr>
					</thead>
					<tbody>
						<?php $row_index = 0; ?>
						<?php foreach ( $report['groups'] as $group ) : ?>
							<?php
							$row_index++;
							$is_wallet = ( 'wallet' === $group['type'] );
							$share     = $report['total'] > 0 ? ( $group['sum'] / $report['total'] ) * 100 : 0;
							?>
							<tr>
								<td class="srevc-cell-index"><?php echo esc_html( Srevc_Format::count_label( $row_index, $settings ) ); ?></td>
								<td>
									<span class="srevc-badge <?php echo $is_wallet ? 'srevc-badge-wallet' : 'srevc-badge-order'; ?>">
										<?php echo esc_html( $is_wallet ? 'شارژ کیف پول' : 'فروش / خدمات' ); ?>
									</span>
								</td>
								<td class="srevc-cell-amount">
									<strong><?php echo esc_html( Srevc_Format::money_words( $group['amount'], $settings ) ); ?></strong>
									<span class="srevc-cell-exact"><?php echo esc_html( Srevc_Format::money( $group['amount'], $settings ) ); ?></span>
								</td>
								<td class="srevc-cell-count"><?php echo esc_html( sprintf( '%s عدد', Srevc_Format::count_label( $group['count'], $settings ) ) ); ?></td>
								<td class="srevc-cell-sum"><?php echo esc_html( Srevc_Format::money( $group['sum'], $settings ) ); ?></td>
								<td class="srevc-cell-share">
									<span class="srevc-share-bar"><span class="srevc-share-fill" style="width:<?php echo esc_attr( min( 100, round( $share, 2 ) ) ); ?>%"></span></span>
									<span class="srevc-share-text"><?php echo esc_html( Srevc_Format::percent( $group['sum'], $report['total'], $settings ) ); ?></span>
								</td>
							</tr>
						<?php endforeach; ?>
					</tbody>
					<tfoot>
						<tr>
							<th colspan="3"><?php esc_html_e( 'جمع کل', 'site-revenue-calculator' ); ?></th>
							<th><?php echo esc_html( sprintf( '%s عدد', Srevc_Format::count_label( $report['count'], $settings ) ) ); ?></th>
							<th colspan="2"><?php echo esc_html( Srevc_Format::money( $report['total'], $settings ) ); ?></th>
						</tr>
					</tfoot>
				</table>
			<?php endif; ?>

			<p class="srevc-footnote">
				<?php
				echo esc_html(
					sprintf(
						'بررسی شده: %s سفارش | ساختار پایگاه داده: %s',
						Srevc_Format::count_label( $report['scanned'], $settings ),
						( 'hpos' === $report['storage'] ) ? 'HPOS' : 'Legacy'
					)
				);
				?>
			</p>
		</div>
		<?php
	}

	protected static function csv_line( $fields ) {
		$cells = array();
		foreach ( (array) $fields as $field ) {
			$cells[] = '"' . str_replace( '"', '""', (string) $field ) . '"';
		}
		return implode( ',', $cells ) . "\r\n";
	}

	public static function export_csv() {
		if ( ! srevc_user_can() ) {
			wp_die( esc_html__( 'شما دسترسی لازم برای دریافت خروجی را ندارید.', 'site-revenue-calculator' ) );
		}

		check_admin_referer( 'srevc_export' );

		$request  = self::current_request();
		$settings = $request['settings'];
		$report   = self::build_report( $request );

		if ( is_wp_error( $report ) ) {
			wp_die( esc_html( $report->get_error_message() ) );
		}

		$filename = 'revenue-' . $report['start'] . '-to-' . $report['end'] . '.csv';

		$body  = "\xEF\xBB\xBF";
		$body .= self::csv_line( array( 'بازه گزارش', Srevc_Range::label( $report['start'], $report['end'] ) ) );
		$body .= self::csv_line( array( 'مبلغ کل', Srevc_Format::raw_number( $report['total'], $settings ), $settings['currency_label'] ) );
		$body .= self::csv_line( array( 'تعداد کل تراکنش', $report['count'] ) );
		$body .= self::csv_line( array( 'شارژ کیف پول', Srevc_Format::raw_number( $report['wallet_total'], $settings ), $report['wallet_count'] ) );
		$body .= self::csv_line( array( 'فروش خدمات', Srevc_Format::raw_number( $report['sales_total'], $settings ), $report['sales_count'] ) );
		$body .= self::csv_line( array( '' ) );
		$body .= self::csv_line( array( 'نوع تراکنش', 'مبلغ هر تراکنش', 'تعداد', 'جمع مبلغ' ) );

		foreach ( $report['groups'] as $group ) {
			$body .= self::csv_line(
				array(
					( 'wallet' === $group['type'] ) ? 'شارژ کیف پول' : 'فروش / خدمات',
					Srevc_Format::raw_number( $group['amount'], $settings ),
					$group['count'],
					Srevc_Format::raw_number( $group['sum'], $settings ),
				)
			);
		}

		nocache_headers();
		header( 'Content-Type: text/csv; charset=utf-8' );
		header( 'Content-Disposition: attachment; filename="' . $filename . '"' );
		header( 'Content-Length: ' . strlen( $body ) );

		echo $body;
		exit;
	}
}
