<?php
defined( 'ABSPATH' ) || exit;

class Srevc_Query {

	public static function is_hpos() {
		if ( class_exists( '\Automattic\WooCommerce\Utilities\OrderUtil' ) && method_exists( '\Automattic\WooCommerce\Utilities\OrderUtil', 'custom_orders_table_usage_is_enabled' ) ) {
			return (bool) \Automattic\WooCommerce\Utilities\OrderUtil::custom_orders_table_usage_is_enabled();
		}
		return false;
	}

	public static function available_statuses() {
		$statuses = array();
		if ( function_exists( 'wc_get_order_statuses' ) ) {
			foreach ( wc_get_order_statuses() as $key => $label ) {
				$statuses[ $key ] = $label;
			}
		}
		return $statuses;
	}

	protected static function prepare( $sql, $args ) {
		global $wpdb;
		if ( empty( $args ) ) {
			return $sql;
		}
		return call_user_func_array( array( $wpdb, 'prepare' ), array_merge( array( $sql ), $args ) );
	}

	protected static function placeholders( $items, $format = '%s' ) {
		return implode( ',', array_fill( 0, count( $items ), $format ) );
	}

	protected static function fetch_orders( $start_gmt, $end_gmt, $statuses ) {
		global $wpdb;

		$status_sql = self::placeholders( $statuses );

		if ( self::is_hpos() ) {
			$orders_table = $wpdb->prefix . 'wc_orders';
			$op_table     = $wpdb->prefix . 'wc_order_operational_data';
			$sql          = "SELECT o.id AS order_id, o.total_amount AS order_total, od.created_via AS created_via, o.payment_method AS payment_method, o.payment_method_title AS payment_method_title, o.customer_id AS customer_id, o.billing_email AS billing_email, o.date_created_gmt AS date_created_gmt
				FROM {$orders_table} o
				LEFT JOIN {$op_table} od ON ( od.order_id = o.id )
				WHERE o.type = %s
				AND o.status IN ( {$status_sql} )
				AND o.date_created_gmt >= %s
				AND o.date_created_gmt <= %s
				ORDER BY o.date_created_gmt ASC";
		} else {
			$sql = "SELECT p.ID AS order_id, total_meta.meta_value AS order_total, via_meta.meta_value AS created_via, pay_meta.meta_value AS payment_method, title_meta.meta_value AS payment_method_title, user_meta.meta_value AS customer_id, email_meta.meta_value AS billing_email, p.post_date_gmt AS date_created_gmt
				FROM {$wpdb->posts} p
				INNER JOIN {$wpdb->postmeta} total_meta ON ( total_meta.post_id = p.ID AND total_meta.meta_key = '_order_total' )
				LEFT JOIN {$wpdb->postmeta} via_meta ON ( via_meta.post_id = p.ID AND via_meta.meta_key = '_created_via' )
				LEFT JOIN {$wpdb->postmeta} pay_meta ON ( pay_meta.post_id = p.ID AND pay_meta.meta_key = '_payment_method' )
				LEFT JOIN {$wpdb->postmeta} title_meta ON ( title_meta.post_id = p.ID AND title_meta.meta_key = '_payment_method_title' )
				LEFT JOIN {$wpdb->postmeta} user_meta ON ( user_meta.post_id = p.ID AND user_meta.meta_key = '_customer_user' )
				LEFT JOIN {$wpdb->postmeta} email_meta ON ( email_meta.post_id = p.ID AND email_meta.meta_key = '_billing_email' )
				WHERE p.post_type = %s
				AND p.post_status IN ( {$status_sql} )
				AND p.post_date_gmt >= %s
				AND p.post_date_gmt <= %s
				ORDER BY p.post_date_gmt ASC";
		}

		$args = array_merge( array( 'shop_order' ), $statuses, array( $start_gmt, $end_gmt ) );
		$rows = $wpdb->get_results( self::prepare( $sql, $args ) );

		return is_array( $rows ) ? $rows : array();
	}

	protected static function coupon_data( $order_ids ) {
		global $wpdb;

		$coupons = array();
		if ( empty( $order_ids ) ) {
			return $coupons;
		}

		$items_table    = $wpdb->prefix . 'woocommerce_order_items';
		$itemmeta_table = $wpdb->prefix . 'woocommerce_order_itemmeta';
		$chunks         = array_chunk( array_map( 'absint', $order_ids ), 500 );

		foreach ( $chunks as $chunk ) {
			$id_sql = self::placeholders( $chunk, '%d' );
			$sql    = "SELECT oi.order_id AS order_id, oi.order_item_name AS code, im.meta_value AS discount
				FROM {$items_table} oi
				LEFT JOIN {$itemmeta_table} im ON ( im.order_item_id = oi.order_item_id AND im.meta_key = %s )
				WHERE oi.order_id IN ( {$id_sql} )
				AND oi.order_item_type = %s";
			$args   = array_merge( array( 'discount_amount' ), $chunk, array( 'coupon' ) );
			$rows   = $wpdb->get_results( self::prepare( $sql, $args ) );

			foreach ( (array) $rows as $row ) {
				$id = (int) $row->order_id;
				if ( ! isset( $coupons[ $id ] ) ) {
					$coupons[ $id ] = array();
				}
				$coupons[ $id ][] = array(
					'code'     => (string) $row->code,
					'discount' => (float) $row->discount,
				);
			}
		}

		return $coupons;
	}

	protected static function wallet_order_ids( $order_ids, $keywords, $product_ids ) {
		global $wpdb;

		$flagged = array();
		if ( empty( $order_ids ) || ( empty( $keywords ) && empty( $product_ids ) ) ) {
			return $flagged;
		}

		$items_table    = $wpdb->prefix . 'woocommerce_order_items';
		$itemmeta_table = $wpdb->prefix . 'woocommerce_order_itemmeta';
		$chunks         = array_chunk( array_map( 'absint', $order_ids ), 500 );

		foreach ( $chunks as $chunk ) {
			$id_sql = self::placeholders( $chunk, '%d' );

			if ( ! empty( $keywords ) ) {
				$like_parts = array();
				$like_args  = array();
				foreach ( $keywords as $keyword ) {
					$like_parts[] = 'oi.order_item_name LIKE %s';
					$like_args[]  = '%' . $wpdb->esc_like( $keyword ) . '%';
				}
				$sql  = "SELECT DISTINCT oi.order_id AS order_id
					FROM {$items_table} oi
					WHERE oi.order_id IN ( {$id_sql} )
					AND oi.order_item_type = %s
					AND ( " . implode( ' OR ', $like_parts ) . ' )';
				$args = array_merge( $chunk, array( 'line_item' ), $like_args );
				$hits = $wpdb->get_col( self::prepare( $sql, $args ) );
				foreach ( (array) $hits as $hit ) {
					$flagged[ (int) $hit ] = true;
				}
			}

			if ( ! empty( $product_ids ) ) {
				$product_sql = self::placeholders( $product_ids, '%d' );
				$sql         = "SELECT DISTINCT oi.order_id AS order_id
					FROM {$items_table} oi
					INNER JOIN {$itemmeta_table} im ON ( im.order_item_id = oi.order_item_id )
					WHERE oi.order_id IN ( {$id_sql} )
					AND oi.order_item_type = %s
					AND im.meta_key IN ( %s, %s )
					AND im.meta_value IN ( {$product_sql} )";
				$args        = array_merge( $chunk, array( 'line_item', '_product_id', '_variation_id' ), $product_ids );
				$hits        = $wpdb->get_col( self::prepare( $sql, $args ) );
				foreach ( (array) $hits as $hit ) {
					$flagged[ (int) $hit ] = true;
				}
			}
		}

		return $flagged;
	}

	public static function split_list( $value ) {
		$value = str_replace( array( '،', "\n", "\r", ';' ), ',', (string) $value );
		$parts = array_map( 'trim', explode( ',', $value ) );
		return array_values( array_filter( $parts, 'strlen' ) );
	}

	public static function run( $args ) {
		global $wpdb;

		$defaults = array(
			'start'                  => '',
			'end'                    => '',
			'statuses'               => array( 'wc-completed' ),
			'exclude_via'            => array(),
			'exclude_zero'           => true,
			'wallet_keywords'        => array(),
			'wallet_products'        => array(),
			'wallet_gateways'        => array(),
			'exclude_wallet_payment' => false,
		);
		$args = wp_parse_args( $args, $defaults );

		$statuses = array_values( array_unique( array_filter( array_map( 'sanitize_text_field', (array) $args['statuses'] ) ) ) );
		if ( empty( $statuses ) ) {
			$statuses = array( 'wc-completed' );
		}

		$start_gmt = get_gmt_from_date( $args['start'] . ' 00:00:00' );
		$end_gmt   = get_gmt_from_date( $args['end'] . ' 23:59:59' );

		$rows = self::fetch_orders( $start_gmt, $end_gmt, $statuses );

		$exclude_via = array_map( 'strtolower', array_map( 'trim', (array) $args['exclude_via'] ) );
		$gateways    = array_map( 'strtolower', array_map( 'trim', (array) $args['wallet_gateways'] ) );
		$keywords    = (array) $args['wallet_keywords'];
		$products    = array_values( array_filter( array_map( 'absint', (array) $args['wallet_products'] ) ) );

		$kept                   = array();
		$skipped_zero           = 0;
		$skipped_via            = 0;
		$skipped_wallet_payment = 0;

		foreach ( $rows as $row ) {
			$total = (float) $row->order_total;
			$via   = strtolower( (string) $row->created_via );
			$pay   = strtolower( (string) $row->payment_method );

			if ( ! empty( $args['exclude_zero'] ) && $total <= 0 ) {
				++$skipped_zero;
				continue;
			}
			if ( ! empty( $exclude_via ) && in_array( $via, $exclude_via, true ) ) {
				++$skipped_via;
				continue;
			}
			if ( ! empty( $args['exclude_wallet_payment'] ) && ! empty( $gateways ) && in_array( $pay, $gateways, true ) ) {
				++$skipped_wallet_payment;
				continue;
			}
			$kept[] = $row;
		}

		$order_ids = wp_list_pluck( $kept, 'order_id' );
		$wallet    = self::wallet_order_ids( $order_ids, $keywords, $products );
		$coupons   = self::coupon_data( $order_ids );

		$groups         = array();
		$payments       = array();
		$coupon_groups  = array();
		$total_revenue  = 0.0;
		$wallet_revenue = 0.0;
		$wallet_count   = 0;
		$manual_revenue = 0.0;
		$manual_count   = 0;
		$gateway_total  = 0.0;
		$gateway_count  = 0;
		$coupon_total   = 0.0;
		$coupon_count   = 0;
		$coupon_saved   = 0.0;

		foreach ( $kept as $row ) {
			$amount    = round( (float) $row->order_total, 2 );
			$id        = (int) $row->order_id;
			$via       = strtolower( (string) $row->created_via );
			$pay       = strtolower( (string) $row->payment_method );
			$is_wallet = isset( $wallet[ $id ] );
			$is_manual = ( 'admin' === $via );
			$type      = $is_wallet ? 'wallet' : 'order';
			$key       = $type . '|' . ( $is_manual ? 'manual' : 'normal' ) . '|' . number_format( $amount, 2, '.', '' );

			if ( ! isset( $groups[ $key ] ) ) {
				$groups[ $key ] = array(
					'type'   => $type,
					'manual' => $is_manual,
					'amount' => $amount,
					'count'  => 0,
					'sum'    => 0.0,
				);
			}
			++$groups[ $key ]['count'];
			$groups[ $key ]['sum'] += $amount;
			$total_revenue         += $amount;

			if ( $is_wallet ) {
				$wallet_revenue += $amount;
				++$wallet_count;
			}
			if ( $is_manual ) {
				$manual_revenue += $amount;
				++$manual_count;
			}
			if ( ! empty( $gateways ) && in_array( $pay, $gateways, true ) ) {
				$gateway_total += $amount;
				++$gateway_count;
			}

			$pay_key = '' !== $pay ? $pay : 'unknown';
			if ( ! isset( $payments[ $pay_key ] ) ) {
				$title = trim( (string) $row->payment_method_title );
				if ( '' === $title ) {
					$title = ( 'unknown' === $pay_key ) ? 'نامشخص' : $pay_key;
				}
				$payments[ $pay_key ] = array(
					'method' => $pay_key,
					'title'  => $title,
					'count'  => 0,
					'sum'    => 0.0,
				);
			}
			++$payments[ $pay_key ]['count'];
			$payments[ $pay_key ]['sum'] += $amount;

			if ( ! empty( $coupons[ $id ] ) ) {
				$coupon_total += $amount;
				++$coupon_count;
				foreach ( $coupons[ $id ] as $coupon ) {
					$code = '' !== $coupon['code'] ? $coupon['code'] : 'بدون کد';
					if ( ! isset( $coupon_groups[ $code ] ) ) {
						$coupon_groups[ $code ] = array(
							'code'     => $code,
							'count'    => 0,
							'sum'      => 0.0,
							'discount' => 0.0,
						);
					}
					++$coupon_groups[ $code ]['count'];
					$coupon_groups[ $code ]['sum']      += $amount;
					$coupon_groups[ $code ]['discount'] += $coupon['discount'];
					$coupon_saved                       += $coupon['discount'];
				}
			}
		}

		$groups = array_values( $groups );
		usort( $groups, array( __CLASS__, 'compare_sum' ) );

		$payments = array_values( $payments );
		usort( $payments, array( __CLASS__, 'compare_sum' ) );

		$coupon_groups = array_values( $coupon_groups );
		usort( $coupon_groups, array( __CLASS__, 'compare_sum' ) );

		$count = count( $kept );

		return array(
			'start'                  => $args['start'],
			'end'                    => $args['end'],
			'statuses'               => $statuses,
			'total'                  => $total_revenue,
			'count'                  => $count,
			'average'                => $count > 0 ? ( $total_revenue / $count ) : 0.0,
			'groups'                 => $groups,
			'payments'               => $payments,
			'coupons'                => $coupon_groups,
			'wallet_total'           => $wallet_revenue,
			'wallet_count'           => $wallet_count,
			'sales_total'            => $total_revenue - $wallet_revenue,
			'sales_count'            => $count - $wallet_count,
			'manual_total'           => $manual_revenue,
			'manual_count'           => $manual_count,
			'gateway_wallet_total'   => $gateway_total,
			'gateway_wallet_count'   => $gateway_count,
			'coupon_total'           => $coupon_total,
			'coupon_count'           => $coupon_count,
			'coupon_discount'        => $coupon_saved,
			'skipped_zero'           => $skipped_zero,
			'skipped_via'            => $skipped_via,
			'skipped_wallet_payment' => $skipped_wallet_payment,
			'scanned'                => count( $rows ),
			'storage'                => self::is_hpos() ? 'hpos' : 'legacy',
			'db_error'               => $wpdb->last_error,
		);
	}

	public static function compare_sum( $a, $b ) {
		if ( $a['sum'] === $b['sum'] ) {
			return $b['count'] <=> $a['count'];
		}
		return ( $b['sum'] < $a['sum'] ) ? -1 : 1;
	}
}
